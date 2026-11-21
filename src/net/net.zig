//! Сокеты и готовность, по операционной системе, выбор при компиляции:
//!
//!   Linux     epoll, sendmsg с MSG_NOSIGNAL
//!   Windows   select, WSASend, Winsock 2.2 — то, что уже было в Windows XP
//!
//! Слушающий сокет один: IPv6 с приёмом IPv4, а где так нельзя — только IPv4.
//!
//! Цикл сервера (server.zig) написан один раз поверх этого файла.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const ws2 = std.os.windows.ws2_32;

pub const is_windows = builtin.os.tag == .windows;
pub const Socket = if (is_windows) ws2.SOCKET else posix.socket_t;
pub const invalid: Socket = if (is_windows) ws2.INVALID_SOCKET else -1;
pub const Interest = enum { in, out };
pub const max_iov = 4;

pub fn startup() !void {
    if (!is_windows) return;
    var data: ws2.WSADATA = undefined;
    if (ws2.WSAStartup(0x0202, &data) != 0) return error.WinsockUnavailable;
}

/// Адрес посетителя: 16 байт IPv6; IPv4 — в виде ::ffff:a.b.c.d.
pub const Ip = [16]u8;

pub fn ip4(a: u8, b: u8, c: u8, d: u8) Ip {
    return [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff, a, b, c, d };
}

pub const loopback = ip4(127, 0, 0, 1);

/// Соединение с этой же машины: 127.0.0.0/8 или ::1.
pub fn isLoopback(ip: Ip) bool {
    const v6_one = [_]u8{0} ** 15 ++ [_]u8{1};
    if (std.mem.eql(u8, &ip, &v6_one)) return true;
    return std.mem.eql(u8, ip[0..12], loopback[0..12]) and ip[12] == 127;
}

/// «192.0.2.7» или «2001:db8::1» (самая длинная цепочка нулевых групп — «::»).
pub fn ipText(buf: *[40]u8, ip: Ip) []const u8 {
    if (std.mem.eql(u8, ip[0..12], ip4(0, 0, 0, 0)[0..12])) {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[12], ip[13], ip[14], ip[15] }) catch unreachable;
    }
    var g: [8]u16 = undefined;
    for (&g, 0..) |*x, i| x.* = std.mem.readInt(u16, ip[2 * i ..][0..2], .big);
    var best_at: usize = 8;
    var best_len: usize = 1; // одна нулевая группа не сокращается
    var i: usize = 0;
    while (i < 8) {
        var j = i;
        while (j < 8 and g[j] == 0) j += 1;
        if (j - i > best_len) {
            best_at = i;
            best_len = j - i;
        }
        i = @max(j, i + 1);
    }
    var w = std.io.fixedBufferStream(buf);
    i = 0;
    while (i < 8) {
        if (i == best_at) {
            w.writer().writeAll("::") catch unreachable;
            i += best_len;
            continue;
        }
        if (i > 0 and i != best_at + best_len) w.writer().writeByte(':') catch unreachable;
        w.writer().print("{x}", .{g[i]}) catch unreachable;
        i += 1;
    }
    return w.getWritten();
}

/// Неблокирующий слушающий сокет на всех адресах: один сокет IPv6, который
/// принимает и IPv4 (IPV6_V6ONLY = 0). Где так нельзя — нет IPv6 или, как в
/// Windows XP, нет двойного стека — сервер слушает только IPv4.
pub fn listen(port: u16) !Socket {
    return listenOn(port, true) catch listenOn(port, false);
}

/// IPPROTO_IPV6 Winsock (в std 0.14 для Windows этой константы нет).
const ipproto_ipv6 = 41;

fn listenOn(port: u16, v6: bool) !Socket {
    const be_port = std.mem.nativeToBig(u16, port);
    if (is_windows) {
        const fd = ws2.socket(if (v6) ws2.AF.INET6 else ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
        if (fd == ws2.INVALID_SOCKET) return error.SocketFailed;
        errdefer _ = ws2.closesocket(fd);
        if (v6) {
            const off = std.mem.toBytes(@as(c_int, 0));
            if (ws2.setsockopt(fd, ipproto_ipv6, ws2.IPV6_V6ONLY, &off, off.len) != 0) return error.NoDualStack;
            var addr = std.mem.zeroes(ws2.sockaddr.in6);
            addr.family = ws2.AF.INET6;
            addr.port = be_port;
            if (ws2.bind(fd, @ptrCast(&addr), @sizeOf(ws2.sockaddr.in6)) != 0) return error.AddressInUse;
        } else {
            var addr = ws2.sockaddr.in{ .port = be_port, .addr = 0 };
            if (ws2.bind(fd, @ptrCast(&addr), @sizeOf(ws2.sockaddr.in)) != 0) return error.AddressInUse;
        }
        if (ws2.listen(fd, 1024) != 0) return error.ListenFailed;
        try nonBlocking(fd);
        return fd;
    }
    const fd = try posix.socket(if (v6) posix.AF.INET6 else posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (v6) {
        try posix.setsockopt(fd, posix.IPPROTO.IPV6, linux.IPV6.V6ONLY, &std.mem.toBytes(@as(c_int, 0)));
        var addr = std.mem.zeroes(posix.sockaddr.in6);
        addr.family = posix.AF.INET6;
        addr.port = be_port;
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in6));
    } else {
        var addr = std.mem.zeroes(posix.sockaddr.in);
        addr.family = posix.AF.INET;
        addr.port = be_port;
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    }
    try posix.listen(fd, 1024);
    return fd;
}

/// Слушающий сокет, унаследованный от главного процесса (воркер на Windows).
/// Winsock помнит «неблокирующий» в памяти процесса, а не в ядре: у воркера
/// сокет снова считается блокирующим, и лишний accept завис бы навсегда.
pub fn adopt(fd: Socket) !void {
    if (is_windows) try nonBlocking(fd);
}

fn nonBlocking(fd: Socket) !void {
    var on: u32 = 1;
    if (ws2.ioctlsocket(fd, ws2.FIONBIO, &on) != 0) return error.SocketFailed;
}

pub const Accepted = struct { fd: Socket, ip: Ip };

/// Адрес собеседника из того, что вернул accept: sockaddr_in или sockaddr_in6.
/// Раскладка первых полей у Windows и Linux одна: семейство (2 байта), порт
/// (2 байта), дальше у IPv4 адрес, у IPv6 — flowinfo (4 байта) и адрес.
fn peerIp(raw: *const [28]u8, v4_family: u16) Ip {
    const family = std.mem.readInt(u16, raw[0..2], .little);
    if (family == v4_family) return ip4(raw[4], raw[5], raw[6], raw[7]);
    return raw[8..24].*;
}

/// Следующее ожидающее соединение (неблокирующее, без алгоритма Нейгла).
pub fn accept(lfd: Socket) ?Accepted {
    var raw: [28]u8 align(4) = [_]u8{0} ** 28;
    if (is_windows) {
        while (true) {
            var len: i32 = raw.len;
            const fd = ws2.accept(lfd, @ptrCast(&raw), &len);
            if (fd == ws2.INVALID_SOCKET) return null;
            nonBlocking(fd) catch {
                _ = ws2.closesocket(fd);
                continue;
            };
            const one = std.mem.toBytes(@as(c_int, 1));
            _ = ws2.setsockopt(fd, ws2.IPPROTO.TCP, ws2.TCP.NODELAY, &one, one.len);
            return .{ .fd = fd, .ip = peerIp(&raw, ws2.AF.INET) };
        }
    }
    var len: posix.socklen_t = raw.len;
    const fd = posix.accept(lfd, @ptrCast(&raw), &len, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return null;
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    return .{ .fd = fd, .ip = peerIp(&raw, posix.AF.INET) };
}

test "адрес посетителя текстом" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("192.0.2.7", ipText(&buf, ip4(192, 0, 2, 7)));
    const cases = [_]struct { [8]u16, []const u8 }{
        .{ .{ 0, 0, 0, 0, 0, 0, 0, 1 }, "::1" },
        .{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, "::" },
        .{ .{ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 1 }, "2001:db8::1" },
        .{ .{ 0x2001, 0xdb8, 0, 1, 0, 0, 0, 0 }, "2001:db8:0:1::" },
        .{ .{ 0x2001, 0, 0x30, 0x4, 0x5, 0x6, 0x7, 0xffff }, "2001:0:30:4:5:6:7:ffff" },
        .{ .{ 0xfe80, 0, 0, 0, 0xa, 0, 0, 1 }, "fe80::a:0:0:1" },
    };
    for (cases) |c| {
        var ip: Ip = undefined;
        for (c[0], 0..) |g, i| std.mem.writeInt(u16, ip[2 * i ..][0..2], g, .big);
        try std.testing.expectEqualStrings(c[1], ipText(&buf, ip));
    }
    var raw = [_]u8{0} ** 28;
    raw[0] = 2;
    raw[4..8].* = .{ 10, 1, 2, 3 };
    try std.testing.expectEqualStrings("10.1.2.3", ipText(&buf, peerIp(&raw, 2)));
    raw[0] = 23;
    raw[23] = 1;
    try std.testing.expectEqualStrings("::1", ipText(&buf, peerIp(&raw, 2)));
}

/// Шлюз приёма соединений между воркерами на Windows — мьютекс, который
/// главный процесс передаёт воркерам по наследству. Слушающий сокет ждёт и
/// зовёт accept только тот, кто держит шлюз.
///
/// Зачем: неблокирующий accept в Winsock — это «проверить, есть ли соединение,
/// и потом ждать его». Когда два процесса проверяют один сокет одновременно,
/// соединение достаётся одному, а второй остаётся ждать внутри accept —
/// вместе со всеми своими уже принятыми соединениями. На Linux accept
/// неделим, и шлюз там не нужен (null).
pub const Gate = if (is_windows) std.os.windows.HANDLE else void;

const gate_api = struct {
    extern "kernel32" fn CreateMutexW(attrs: ?*anyopaque, owned: std.os.windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn ReleaseMutex(h: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(h: std.os.windows.HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn SetHandleInformation(h: std.os.windows.HANDLE, mask: u32, flags: u32) callconv(.winapi) std.os.windows.BOOL;
};

/// Новый шлюз, наследуемый дочерними процессами. null — не Windows или отказ системы.
pub fn gateCreate() ?Gate {
    if (!is_windows) return null;
    const h = gate_api.CreateMutexW(null, 0, null) orelse return null;
    _ = gate_api.SetHandleInformation(h, 1, 1);
    return h;
}

/// true — шлюз наш (в том числе брошенный упавшим воркером).
pub fn gateTryEnter(g: Gate) bool {
    if (!is_windows) return true;
    const r = gate_api.WaitForSingleObject(g, 0);
    return r == 0 or r == 0x80;
}

pub fn gateLeave(g: Gate) void {
    if (is_windows) _ = gate_api.ReleaseMutex(g);
}

pub const ReadError = error{ WouldBlock, Failed };
pub const WriteError = error{ WouldBlock, Broken };

/// 0 — собеседник закрыл свою сторону.
pub fn read(fd: Socket, buf: []u8) ReadError!usize {
    if (is_windows) {
        const n = ws2.recv(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0);
        if (n >= 0) return @intCast(n);
        return if (ws2.WSAGetLastError() == .WSAEWOULDBLOCK) error.WouldBlock else error.Failed;
    }
    return posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => error.WouldBlock,
        else => error.Failed,
    };
}

/// Список срезов одним вызовом (scatter-gather).
pub fn sendv(fd: Socket, iov: []const posix.iovec_const) WriteError!usize {
    if (is_windows) {
        var bufs: [max_iov]ws2.WSABUF = undefined;
        const n = @min(iov.len, bufs.len);
        for (iov[0..n], bufs[0..n]) |v, *b| b.* = .{ .len = @intCast(@min(v.len, std.math.maxInt(u32))), .buf = @constCast(v.base) };
        var sent: u32 = 0;
        if (ws2.WSASend(fd, &bufs, @intCast(n), &sent, 0, null, null) == 0) return sent;
        return if (ws2.WSAGetLastError() == .WSAEWOULDBLOCK) error.WouldBlock else error.Broken;
    }
    const msg = linux.msghdr_const{ .name = null, .namelen = 0, .iov = iov.ptr, .iovlen = @intCast(iov.len), .control = null, .controllen = 0, .flags = 0 };
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.Broken,
        }
    }
}

pub fn send(fd: Socket, bytes: []const u8) WriteError!usize {
    const iov = [1]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    return sendv(fd, &iov);
}

pub fn shutdownSend(fd: Socket) void {
    if (is_windows) _ = ws2.shutdown(fd, ws2.SD_SEND) else posix.shutdown(fd, .send) catch {};
}

pub fn close(fd: Socket) void {
    if (is_windows) _ = ws2.closesocket(fd) else posix.close(fd);
}

/// Какие сокеты готовы. У каждого метка: номер слота + 1, 0 — слушающий.
pub const Poller = if (is_windows) SelectPoller else EpollPoller;

const EpollPoller = struct {
    ep: i32,
    events: []linux.epoll_event,

    pub fn init(gpa: std.mem.Allocator, max: u32) !EpollPoller {
        return .{ .ep = try posix.epoll_create1(linux.EPOLL.CLOEXEC), .events = try gpa.alloc(linux.epoll_event, @min(max, 256)) };
    }

    fn mask(i: Interest) u32 {
        return switch (i) {
            .in => linux.EPOLL.IN,
            .out => linux.EPOLL.OUT,
        };
    }

    pub fn add(self: *EpollPoller, fd: Socket, tag: u32, i: Interest) !void {
        var ev = linux.epoll_event{ .events = mask(i), .data = .{ .ptr = tag } };
        try posix.epoll_ctl(self.ep, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    pub fn modify(self: *EpollPoller, fd: Socket, tag: u32, i: Interest) !void {
        var ev = linux.epoll_event{ .events = mask(i), .data = .{ .ptr = tag } };
        try posix.epoll_ctl(self.ep, linux.EPOLL.CTL_MOD, fd, &ev);
    }

    pub fn remove(_: *EpollPoller, _: Socket, _: u32) void {}

    pub fn wait(self: *EpollPoller, timeout_ms: i32, out: []u32) usize {
        const n = posix.epoll_wait(self.ep, self.events[0..@min(self.events.len, out.len)], timeout_ms);
        for (self.events[0..n], out[0..n]) |ev, *t| t.* = @intCast(ev.data.ptr);
        return n;
    }
};

const SelectPoller = struct {
    socks: []Socket,
    interest: []?Interest,
    tag_of: std.AutoHashMapUnmanaged(usize, u32) = .{},
    /// fd_set Winsock — счётчик и массив сокетов; массив здесь на все метки.
    read_set: []usize,
    write_set: []usize,

    pub fn init(gpa: std.mem.Allocator, max: u32) !SelectPoller {
        const n = max + 1;
        var p = SelectPoller{
            .socks = try gpa.alloc(Socket, n),
            .interest = try gpa.alloc(?Interest, n),
            .read_set = try gpa.alloc(usize, n + 1),
            .write_set = try gpa.alloc(usize, n + 1),
        };
        @memset(p.interest, null);
        try p.tag_of.ensureTotalCapacity(gpa, 2 * n);
        return p;
    }

    pub fn add(self: *SelectPoller, fd: Socket, tag: u32, i: Interest) !void {
        self.socks[tag] = fd;
        self.interest[tag] = i;
        self.tag_of.putAssumeCapacity(@intFromPtr(fd), tag);
    }

    pub fn modify(self: *SelectPoller, _: Socket, tag: u32, i: Interest) !void {
        self.interest[tag] = i;
    }

    pub fn remove(self: *SelectPoller, fd: Socket, tag: u32) void {
        self.interest[tag] = null;
        _ = self.tag_of.remove(@intFromPtr(fd));
    }

    pub fn wait(self: *SelectPoller, timeout_ms: i32, out: []u32) usize {
        var nr: usize = 0;
        var nw: usize = 0;
        for (self.interest, self.socks) |i, fd| {
            const set, const k = switch (i orelse continue) {
                .in => .{ self.read_set, &nr },
                .out => .{ self.write_set, &nw },
            };
            set[1 + k.*] = @intFromPtr(fd);
            k.* += 1;
        }
        self.read_set[0] = nr;
        self.write_set[0] = nw;
        const tv = ws2.timeval{ .sec = @divTrunc(timeout_ms, 1000), .usec = @rem(timeout_ms, 1000) * 1000 };
        const rc = ws2.select(0, @ptrCast(self.read_set.ptr), if (nw > 0) @ptrCast(self.write_set.ptr) else null, null, &tv);
        if (rc <= 0) return 0;
        var n: usize = 0;
        for ([_][]usize{ self.read_set, self.write_set }, [_]bool{ true, nw > 0 }) |set, used| {
            if (!used) continue;
            for (set[1..][0..set[0]]) |fd| {
                if (n == out.len) return n;
                out[n] = self.tag_of.get(fd) orelse continue;
                n += 1;
            }
        }
        return n;
    }
};
