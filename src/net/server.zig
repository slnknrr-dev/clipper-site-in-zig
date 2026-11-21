//! Цикл событий: один поток, неблокирующие сокеты, готовность от системы
//! (epoll или select — net.zig). Слоты соединений выделяются один раз при
//! старте. Ответ уходит одним вызовом из двух срезов — заголовок и тело;
//! тело лежит в общем буфере страницы, в кэше или в снимке и копируется
//! в кучу только тогда, когда сокет не принял его целиком.

const std = @import("std");
const posix = std.posix;
const net = @import("net.zig");
const tls = @import("tls.zig");
const http = @import("../http.zig");
const sys = @import("../sys.zig");

pub const idle_timeout_s = 15;
pub const linger_s = 2;
/// Сколько соединений воркер принимает за один заход в шлюз.
const gate_batch = 16;
const in_bytes = http.limits.head_bytes + 8192;

pub const Reply = struct {
    status: u16 = 200,
    ctype: []const u8 = "text/html; charset=windows-1251",
    body: []const u8 = "",
    /// Тело из кучи (`gpa` сервера): сервер освободит его после отправки.
    owned: ?[]u8 = null,
    extra: [3072]u8 = undefined,
    extra_len: usize = 0,
    close: bool = false,

    /// Строка заголовка; "\r\n" дописывается.
    pub fn header(r: *Reply, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(r.extra[r.extra_len..], fmt ++ "\r\n", args) catch return;
        r.extra_len += s.len;
    }
};

/// Что сервер знает о приложении.
pub const App = struct {
    ctx: *anyopaque,
    /// Заполняет ответ. `body` живёт до возврата.
    handle: *const fn (ctx: *anyopaque, req: *const http.Request, body: []const u8, ip: net.Ip, tls_on: bool, reply: *Reply) void,
    /// Наибольшее тело, которое этот запрос вправе прислать (до чтения тела).
    body_limit: *const fn (ctx: *anyopaque, req: *const http.Request) u64,
    /// Раз в секунду.
    tick: *const fn (ctx: *anyopaque, now: i64) void,
    /// Папка для временных файлов загрузок.
    tmp_dir: std.fs.Dir,
};

const State = enum { idle, reading, writing, draining, receiving };

const Conn = struct {
    fd: net.Socket = net.invalid,
    state: State = .idle,
    ip: net.Ip = net.loopback,
    in: [in_bytes]u8 = undefined,
    in_len: usize = 0,
    head: [4096]u8 = undefined,
    head_len: usize = 0,
    head_off: usize = 0,
    body: []const u8 = "",
    owned: ?[]u8 = null,
    close_after: bool = false,
    deadline: i64 = 0,
    /// Длинное тело формы — в куче; заголовок запроса тем временем остаётся в `in`.
    big: ?[]u8 = null,
    big_len: usize = 0,
    big_req: http.Request = undefined,
    /// Загрузка, которая пишется в файл по мере прихода.
    up: ?std.fs.File = null,
    up_left: u64 = 0,
    up_name: [40]u8 = undefined,
    up_name_len: u8 = 0,
    tls: ?*tls.Session = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    app: App,
    tls_cfg: ?*const tls.Config,
    poller: net.Poller,
    lfd: net.Socket,
    conns: []Conn,
    free: []u32,
    free_n: usize,
    now: i64 = 0,
    stop: bool = false,
    /// Шлюз приёма (несколько воркеров на Windows, см. net.Gate).
    gate: ?net.Gate = null,
    listening: bool = true,
    /// До этого времени (мс) воркер не берёт шлюз: дать очередь соседям.
    gate_after: i64 = 0,

    /// lfd — слушающий сокет (net.listen); у воркеров он один на всех.
    pub fn init(gpa: std.mem.Allocator, lfd: net.Socket, max_conns: u32, app: App, tls_cfg: ?*const tls.Config) !Server {
        const conns = try gpa.alloc(Conn, max_conns);
        const free = try gpa.alloc(u32, max_conns);
        for (conns, 0..) |*c, i| {
            c.fd = net.invalid;
            c.state = .idle;
            c.owned = null;
            c.big = null;
            c.up = null;
            c.up_name_len = 0;
            c.tls = null;
            c.body = "";
            free[i] = @intCast(conns.len - 1 - i);
        }
        var poller = try net.Poller.init(gpa, max_conns);
        try poller.add(lfd, 0, .in);
        return .{ .gpa = gpa, .app = app, .tls_cfg = tls_cfg, .poller = poller, .lfd = lfd, .conns = conns, .free = free, .free_n = free.len };
    }

    pub fn deinit(self: *Server) void {
        for (self.conns) |*c| self.closeConn(c);
        net.close(self.lfd);
    }

    pub fn run(self: *Server) void {
        const ready = self.gpa.alloc(u32, self.conns.len + 1) catch return;
        defer self.gpa.free(ready);
        var last: i64 = 0;
        while (!self.stop) {
            // Со шлюзом слушающий сокет ждёт только его владелец; остальные
            // заглядывают за шлюзом каждые 10 мс.
            if (self.gate) |g| {
                const mine = sys.nowMs() >= self.gate_after and net.gateTryEnter(g);
                if (mine != self.listening) {
                    if (mine) self.poller.add(self.lfd, 0, .in) catch {} else self.poller.remove(self.lfd, 0);
                    self.listening = mine;
                }
            }
            const n = self.poller.wait(if (self.listening) 1000 else 10, ready);
            self.now = sys.now();
            // Сначала приём: шлюз отпускается до того, как начнётся работа над запросами.
            if (self.gate) |g| {
                var taken: usize = 0;
                if (self.listening) {
                    for (ready[0..n]) |tag| if (tag == 0) {
                        taken = self.acceptAll(gate_batch);
                    };
                    net.gateLeave(g);
                    // взял пачку — пропусти ход, иначе один воркер заберёт всё
                    if (taken > 0) self.gate_after = sys.nowMs() + 1;
                }
                for (ready[0..n]) |tag| if (tag != 0) self.onEvent(&self.conns[tag - 1]);
            } else for (ready[0..n]) |tag| {
                if (tag == 0) _ = self.acceptAll(std.math.maxInt(usize)) else self.onEvent(&self.conns[tag - 1]);
            }
            if (self.now != last) {
                last = self.now;
                for (self.conns) |*c| {
                    if (c.state != .idle and self.now >= c.deadline) self.closeConn(c);
                }
                self.app.tick(self.app.ctx, self.now);
            }
        }
    }

    fn index(self: *const Server, c: *const Conn) u32 {
        return @intCast((@intFromPtr(c) - @intFromPtr(self.conns.ptr)) / @sizeOf(Conn));
    }

    /// Принимает до limit ожидающих соединений; возвращает, сколько принято.
    fn acceptAll(self: *Server, limit: usize) usize {
        var taken: usize = 0;
        while (taken < limit) : (taken += 1) {
            const a = net.accept(self.lfd) orelse break;
            if (self.free_n == 0) {
                net.close(a.fd); // всё занято: отказать лучше, чем копить очередь
                continue;
            }
            self.free_n -= 1;
            const idx = self.free[self.free_n];
            const c = &self.conns[idx];
            c.fd = a.fd;
            c.ip = a.ip;
            c.state = .reading;
            c.in_len = 0;
            c.head_len = 0;
            c.head_off = 0;
            c.body = "";
            c.close_after = false;
            c.deadline = self.now + idle_timeout_s;
            if (self.tls_cfg) |cfg| {
                c.tls = tls.Session.create(self.gpa, cfg) catch {
                    c.state = .idle;
                    net.close(a.fd);
                    self.free[self.free_n] = idx;
                    self.free_n += 1;
                    continue;
                };
            }
            self.poller.add(a.fd, idx + 1, .in) catch self.closeConn(c);
        }
        return taken;
    }

    fn connRead(c: *Conn, buf: []u8) net.ReadError!usize {
        if (c.tls) |t| return t.read(c.fd, buf);
        return net.read(c.fd, buf);
    }

    fn onEvent(self: *Server, c: *Conn) void {
        switch (c.state) {
            .reading => self.onReadable(c),
            .writing => if (self.flush(c)) self.process(c),
            .draining => self.drain(c),
            .receiving => if (c.big != null) self.onBig(c) else self.onUpload(c),
            .idle => {},
        }
    }

    fn onReadable(self: *Server, c: *Conn) void {
        var eof = false;
        while (c.in_len < c.in.len) {
            const n = connRead(c, c.in[c.in_len..]) catch |err| switch (err) {
                error.WouldBlock => break,
                error.Failed => return self.closeConn(c),
            };
            if (n == 0) {
                eof = true;
                break;
            }
            c.in_len += n;
        }
        c.deadline = self.now + idle_timeout_s;
        // Рукопожатие TLS могло оставить неотправленные байты.
        if (c.tls) |t| if (t.pending() > 0) {
            if (!self.flush(c)) return;
        };
        self.process(c);
        if (eof and c.state == .reading) self.closeConn(c);
    }

    /// Отвечает на каждый полный запрос в буфере, по порядку (pipelining).
    fn process(self: *Server, c: *Conn) void {
        while (c.state == .reading) {
            switch (http.parse(c.in[0..c.in_len])) {
                .incomplete => return,
                .fail => |status| {
                    self.failReply(c, status);
                    c.in_len = 0;
                },
                .ok => |req| {
                    var used = req.head_len;
                    var body: []const u8 = "";
                    if (req.method == .POST and req.content_length > 0) {
                        if (req.content_length > self.app.body_limit(self.app.ctx, &req)) {
                            self.failReply(c, 413); // тело не читается: его съест закрытие с ожиданием
                            c.in_len = 0;
                            if (!self.flush(c)) return;
                            continue;
                        }
                        if (req.content_length > c.in.len - req.head_len) {
                            self.startBody(c, req);
                            if (c.state == .receiving) return;
                            if (!self.flush(c)) return;
                            continue;
                        }
                        const end = req.head_len + @as(usize, @intCast(req.content_length));
                        if (c.in_len < end) return; // остаток тела ещё в пути
                        body = c.in[req.head_len..end];
                        used = end;
                    }
                    self.respond(c, &req, body);
                    if (c.close_after) {
                        c.in_len = 0;
                    } else {
                        const rest = c.in_len - used;
                        std.mem.copyForwards(u8, c.in[0..rest], c.in[used..c.in_len]);
                        c.in_len = rest;
                    }
                },
            }
            if (!self.flush(c)) return;
        }
    }

    fn respond(self: *Server, c: *Conn, req: *const http.Request, body: []const u8) void {
        var reply = Reply{};
        self.app.handle(self.app.ctx, req, body, c.ip, c.tls != null, &reply);
        self.setReply(c, &reply, req.keep_alive, req.http10, req.method == .HEAD);
    }

    fn failReply(self: *Server, c: *Conn, status: u16) void {
        var reply = Reply{ .status = status, .ctype = "text/plain; charset=utf-8", .close = true };
        reply.body = http.reason(status);
        if (status == 405) reply.header("Allow: GET, HEAD, POST", .{});
        self.setReply(c, &reply, false, false, false);
    }

    fn setReply(self: *Server, c: *Conn, r: *const Reply, keep_alive: bool, http10: bool, head_only: bool) void {
        const keep = keep_alive and !r.close;
        var date: [29]u8 = undefined;
        const conn_line: []const u8 = if (!keep) "Connection: close\r\n" else if (http10) "Connection: keep-alive\r\n" else "";
        const head = std.fmt.bufPrint(&c.head, "HTTP/1.1 {d} {s}\r\nServer: clipper\r\nDate: {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}{s}\r\n", .{
            r.status, http.reason(r.status), http.httpDate(&date, self.now), r.ctype, r.body.len, conn_line, r.extra[0..r.extra_len],
        }) catch unreachable; // extra ≤ 3072, остальное — сотни байт
        c.head_len = head.len;
        c.head_off = 0;
        c.body = if (head_only) "" else r.body;
        c.owned = r.owned;
        c.close_after = !keep;
    }

    /// Пишет, сколько берёт сокет. true — всё отправлено, соединение ждёт следующий запрос.
    fn flush(self: *Server, c: *Conn) bool {
        while (c.head_off < c.head_len or c.body.len > 0) {
            const hrest = c.head[c.head_off..c.head_len];
            const w = self.connWrite(c, hrest, c.body) catch |err| switch (err) {
                error.WouldBlock => return self.park(c),
                error.Broken => {
                    self.closeConn(c);
                    return false;
                },
            };
            c.deadline = self.now + idle_timeout_s;
            const hw = @min(w, hrest.len);
            c.head_off += hw;
            c.body = c.body[w - hw ..];
        }
        if (c.tls) |t| {
            t.flush(c.fd) catch |err| switch (err) {
                error.WouldBlock => return self.park(c),
                error.Broken => {
                    self.closeConn(c);
                    return false;
                },
            };
        }
        if (c.owned) |o| {
            self.gpa.free(o);
            c.owned = null;
        }
        c.head_len = 0;
        c.head_off = 0;
        if (c.state == .writing) {
            c.state = .reading;
            self.watch(c, .in);
            if (c.state == .idle) return false;
        }
        if (c.close_after) {
            self.linger(c);
            return false;
        }
        return true;
    }

    fn connWrite(_: *Server, c: *Conn, head: []const u8, body: []const u8) net.WriteError!usize {
        if (c.tls) |t| return t.write(c.fd, if (head.len > 0) head else body);
        var iov: [2]posix.iovec_const = undefined;
        var n: usize = 0;
        if (head.len > 0) {
            iov[n] = .{ .base = head.ptr, .len = head.len };
            n += 1;
        }
        if (body.len > 0) {
            iov[n] = .{ .base = body.ptr, .len = body.len };
            n += 1;
        }
        return net.sendv(c.fd, iov[0..n]);
    }

    /// Сокет полон: остаток тела переезжает в кучу (общий буфер страницы
    /// нужен следующему запросу), соединение ждёт готовности к записи.
    fn park(self: *Server, c: *Conn) bool {
        if (c.owned == null and c.body.len > 0) {
            const copy = self.gpa.dupe(u8, c.body) catch {
                self.closeConn(c);
                return false;
            };
            c.owned = copy;
            c.body = copy;
        }
        if (c.state != .writing) {
            c.state = .writing;
            self.watch(c, .out);
        }
        return false;
    }

    /// Закрытие с ожиданием: перестать писать, недолго читать и выбрасывать.
    /// Закрытие сокета с непрочитанным входом шлёт RST, а он может уничтожить
    /// ответ, который клиент ещё не прочёл (413, 431).
    fn linger(self: *Server, c: *Conn) void {
        if (c.tls) |t| t.shutdown(c.fd);
        net.shutdownSend(c.fd);
        c.state = .draining;
        c.deadline = self.now + linger_s;
        self.drain(c);
    }

    fn drain(self: *Server, c: *Conn) void {
        var sink: [4096]u8 = undefined;
        while (true) {
            const n = net.read(c.fd, &sink) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Failed => return self.closeConn(c),
            };
            if (n == 0) return self.closeConn(c);
        }
    }

    fn watch(self: *Server, c: *Conn, i: net.Interest) void {
        self.poller.modify(c.fd, self.index(c) + 1, i) catch self.closeConn(c);
    }

    fn closeConn(self: *Server, c: *Conn) void {
        if (c.state == .idle) return;
        if (c.owned) |o| self.gpa.free(o);
        c.owned = null;
        c.body = "";
        if (c.big) |b| self.gpa.free(b);
        c.big = null;
        self.dropUpload(c);
        if (c.tls) |t| t.destroy(self.gpa);
        c.tls = null;
        self.poller.remove(c.fd, self.index(c) + 1);
        net.close(c.fd);
        c.fd = net.invalid;
        c.state = .idle;
        self.free[self.free_n] = self.index(c);
        self.free_n += 1;
    }

    // ───────────── длинные тела ─────────────

    /// Тело не помещается за заголовком: до 64 КБ — в кучу, больше — в файл.
    fn startBody(self: *Server, c: *Conn, req: http.Request) void {
        const have = c.in_len - req.head_len;
        c.big_req = req;
        if (req.content_length <= http.limits.form_body) {
            const buf = self.gpa.alloc(u8, @intCast(req.content_length)) catch return self.failBody(c, 503);
            @memcpy(buf[0..have], c.in[req.head_len..c.in_len]);
            c.big = buf;
            c.big_len = have;
            c.in_len = req.head_len; // заголовок остаётся: на него указывают срезы запроса
            c.state = .receiving;
            return self.onBig(c);
        }
        var raw: [8]u8 = undefined;
        sys.random(&raw);
        const name = std.fmt.bufPrint(&c.up_name, "up-{s}.part", .{std.fmt.fmtSliceHexLower(&raw)}) catch unreachable;
        c.up_name_len = @intCast(name.len);
        const file = self.app.tmp_dir.createFile(name, .{ .read = true }) catch return self.failBody(c, 500);
        c.up = file;
        file.writeAll(c.in[req.head_len..c.in_len]) catch return self.failBody(c, 500);
        c.up_left = req.content_length - have;
        c.in_len = req.head_len;
        c.state = .receiving;
        self.onUpload(c);
    }

    fn failBody(self: *Server, c: *Conn, status: u16) void {
        self.dropUpload(c);
        self.failReply(c, status);
        c.in_len = 0;
    }

    fn onBig(self: *Server, c: *Conn) void {
        const buf = c.big.?;
        while (c.big_len < buf.len) {
            const n = connRead(c, buf[c.big_len..]) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Failed => return self.closeConn(c),
            };
            if (n == 0) return self.closeConn(c);
            c.big_len += n;
            c.deadline = self.now + idle_timeout_s;
        }
        c.state = .reading;
        self.respond(c, &c.big_req, buf);
        self.gpa.free(buf);
        c.big = null;
        c.in_len = 0;
        if (self.flush(c)) self.process(c);
    }

    fn onUpload(self: *Server, c: *Conn) void {
        var chunk: [32 * 1024]u8 = undefined;
        while (c.up_left > 0) {
            const want: usize = @intCast(@min(c.up_left, chunk.len));
            const n = connRead(c, chunk[0..want]) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Failed => return self.closeConn(c),
            };
            if (n == 0) return self.closeConn(c); // клиент передумал
            c.up.?.writeAll(chunk[0..n]) catch return self.closeConn(c);
            c.up_left -= n;
            c.deadline = self.now + idle_timeout_s;
        }
        // Файл целиком на диске: теперь его можно разобрать.
        const len: usize = @intCast(c.big_req.content_length);
        c.state = .reading;
        const buf = self.gpa.alloc(u8, len) catch {
            self.failBody(c, 503);
            if (self.flush(c)) self.process(c);
            return;
        };
        defer self.gpa.free(buf);
        const got = c.up.?.preadAll(buf, 0) catch 0;
        self.dropUpload(c);
        if (got != len) self.failReply(c, 500) else self.respond(c, &c.big_req, buf);
        c.in_len = 0;
        if (self.flush(c)) self.process(c);
    }

    fn dropUpload(self: *Server, c: *Conn) void {
        if (c.up) |f| f.close();
        c.up = null;
        if (c.up_name_len > 0) self.app.tmp_dir.deleteFile(c.up_name[0..c.up_name_len]) catch {};
        c.up_name_len = 0;
    }
};
