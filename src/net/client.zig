//! Исходящий запрос GET — один, короткий, с общим сроком. Нужен федерации:
//! сайт, на который пришёл гость, спрашивает его родной сайт, настоящий ли
//! билет (fed.zig). Запрос идёт прямо в цикле событий: пока он не кончится
//! (не дольше `budget_ms`), процесс других посетителей не обслуживает.
//!
//! https — клиент TLS из std с проверкой сертификата по хранилищу системы.
//! На Windows это хранилище «ROOT» как есть: корневые сертификаты, которых
//! система ещё не подгружала сама, в нём отсутствуют, и сайт с таким корнем
//! проверку не пройдёт, пока корень не появится в хранилище.
//! Он спрашивает время у функции, которой нет до Windows 8, поэтому в сборке
//! под Windows XP его нет вовсе (`tls_ok`): там с сайтами https связи нет.

const std = @import("std");
const builtin = @import("builtin");
const net = @import("net.zig");
const sys = @import("../sys.zig");
const posix = std.posix;
const ws2 = std.os.windows.ws2_32;

pub const tls_ok = !net.is_windows or (builtin.os.isAtLeast(.windows, .win8) orelse false);

/// Общий срок запроса: имя, соединение, рукопожатие, ответ.
pub const budget_ms = 8000;
const max_response = 16 * 1024;

pub const Error = error{
    /// адрес не разобран
    BadAddress,
    /// имя не найдено
    Resolve,
    /// имя ведёт во внутреннюю сеть, а сайт в списке федерации не назван
    Private,
    Connect,
    Timeout,
    /// сертификат не принят или рукопожатие не удалось
    Tls,
    /// эта сборка не умеет https (Windows XP)
    NoTls,
    /// ответ — не HTTP
    Protocol,
    OutOfMemory,
};

pub const Response = struct { status: u16, body: []const u8 };

pub const HostPort = struct { host: []const u8, port: u16 };

/// «example.com», «example.com:8443», «[::1]:3000».
pub fn splitHostPort(s: []const u8, default_port: u16) ?HostPort {
    if (s.len == 0) return null;
    if (s[0] == '[') {
        const end = std.mem.indexOfScalar(u8, s, ']') orelse return null;
        if (end < 2) return null;
        if (end + 1 == s.len) return .{ .host = s[1..end], .port = default_port };
        if (s[end + 1] != ':') return null;
        return .{ .host = s[1..end], .port = std.fmt.parseInt(u16, s[end + 2 ..], 10) catch return null };
    }
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        if (colon == 0 or std.mem.indexOfScalar(u8, s[0..colon], ':') != null) return null;
        const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
        if (port == 0) return null;
        return .{ .host = s[0..colon], .port = port };
    }
    return .{ .host = s, .port = default_port };
}

fn private4(b: [4]u8) bool {
    return b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224 or
        (b[0] == 100 and b[1] & 0xC0 == 64) or (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and b[1] & 0xF0 == 16) or (b[0] == 192 and b[1] == 168);
}

/// Адрес этой машины или внутренней сети: туда сервер не ходит по чужой подсказке.
pub fn isPrivate(addr: std.net.Address) bool {
    if (addr.any.family == posix.AF.INET) return private4(@bitCast(addr.in.sa.addr));
    if (addr.any.family != posix.AF.INET6) return true;
    const b = addr.in6.sa.addr;
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) return private4(b[12..16].*);
    if (std.mem.allEqual(u8, b[0..15], 0)) return true; // :: и ::1
    return b[0] & 0xFE == 0xFC or (b[0] == 0xFE and b[1] & 0xC0 == 0x80) or b[0] == 0xFF;
}

/// Ждёт готовности сокета до срока. false — срок вышел.
fn wait(fd: net.Socket, write: bool, deadline: i64) bool {
    const left = deadline - sys.nowMs();
    if (left <= 0) return false;
    const ms: i32 = @intCast(@min(left, budget_ms));
    if (net.is_windows) {
        // fd_set Winsock: счётчик и массив сокетов
        var set = [2]usize{ 1, @intFromPtr(fd) };
        var bad = set;
        const tv = ws2.timeval{ .sec = @divTrunc(ms, 1000), .usec = @rem(ms, 1000) * 1000 };
        const rc = if (write) ws2.select(0, null, @ptrCast(&set), @ptrCast(&bad), &tv) else ws2.select(0, @ptrCast(&set), null, @ptrCast(&bad), &tv);
        return rc > 0;
    }
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = if (write) posix.POLL.OUT else posix.POLL.IN, .revents = 0 }};
    return (posix.poll(&fds, ms) catch 0) > 0;
}

fn connect(addr: std.net.Address, deadline: i64) Error!net.Socket {
    if (net.is_windows) {
        const fd = ws2.socket(addr.any.family, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
        if (fd == ws2.INVALID_SOCKET) return error.Connect;
        errdefer net.close(fd);
        var on: u32 = 1;
        if (ws2.ioctlsocket(fd, ws2.FIONBIO, &on) != 0) return error.Connect;
        if (ws2.connect(fd, @ptrCast(&addr.any), @intCast(addr.getOsSockLen())) != 0 and ws2.WSAGetLastError() != .WSAEWOULDBLOCK) return error.Connect;
        if (!wait(fd, true, deadline)) return error.Timeout;
        var err: i32 = 0;
        var len: i32 = @sizeOf(i32);
        if (ws2.getsockopt(fd, ws2.SOL.SOCKET, ws2.SO.ERROR, @ptrCast(&err), &len) != 0 or err != 0) return error.Connect;
        return fd;
    }
    const fd = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch return error.Connect;
    errdefer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {},
        else => return error.Connect,
    };
    if (!wait(fd, true, deadline)) return error.Timeout;
    posix.getsockoptError(fd) catch return error.Connect;
    return fd;
}

/// Неблокирующий сокет со сроком — в том виде, какого ждёт клиент TLS из std.
const Sock = struct {
    fd: net.Socket,
    deadline: i64,

    pub const ReadError = error{ Timeout, Failed };
    pub const WriteError = error{ Timeout, Broken };

    pub fn read(s: Sock, buf: []u8) ReadError!usize {
        while (true) {
            return net.read(s.fd, buf) catch |e| switch (e) {
                error.WouldBlock => {
                    if (!wait(s.fd, false, s.deadline)) return error.Timeout;
                    continue;
                },
                error.Failed => return error.Failed,
            };
        }
    }

    /// Не меньше `len` байт; меньше — только если собеседник закрыл соединение.
    pub fn readAtLeast(s: Sock, buf: []u8, len: usize) ReadError!usize {
        var n: usize = 0;
        while (n < len) {
            const got = try s.read(buf[n..]);
            if (got == 0) break;
            n += got;
        }
        return n;
    }

    pub fn readv(s: Sock, iov: []const posix.iovec) ReadError!usize {
        for (iov) |v| if (v.len > 0) return s.read(v.base[0..v.len]);
        return 0;
    }

    pub fn writeAll(s: Sock, bytes: []const u8) WriteError!void {
        var at: usize = 0;
        while (at < bytes.len) {
            at += net.send(s.fd, bytes[at..]) catch |e| switch (e) {
                error.WouldBlock => {
                    if (!wait(s.fd, true, s.deadline)) return error.Timeout;
                    continue;
                },
                error.Broken => return error.Broken,
            };
        }
    }

    pub fn writev(s: Sock, iov: []const posix.iovec_const) WriteError!usize {
        for (iov) |v| if (v.len > 0) {
            try s.writeAll(v.base[0..v.len]);
            return v.len;
        };
        return 0;
    }

    pub fn writevAll(s: Sock, iov: []posix.iovec_const) WriteError!void {
        for (iov) |v| try s.writeAll(v.base[0..v.len]);
    }
};

/// Корневые сертификаты системы: читаются один раз на процесс.
var bundle: std.crypto.Certificate.Bundle = .{};
var bundle_loaded = false;

/// Весь ответ целиком: до закрытия соединения, конца тела или предела.
fn complete(buf: []const u8) bool {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return false;
    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
    while (lines.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch return false;
            return buf.len >= head_end + 4 + n;
        }
    }
    return std.mem.endsWith(u8, buf, "\r\n0\r\n\r\n"); // chunked
}

fn parseResponse(a: std.mem.Allocator, buf: []const u8) Error!Response {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Protocol;
    const head = buf[0..head_end];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.") or head[8] != ' ') return error.Protocol;
    const status = std.fmt.parseInt(u16, head[9..12], 10) catch return error.Protocol;
    var body = buf[head_end + 4 ..];
    var chunked = false;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch return error.Protocol;
            // длиннее предела — остаётся начало: ответ участника федерации короток
            body = body[0..@min(n, body.len)];
        } else if (line.len > 18 and std.ascii.eqlIgnoreCase(line[0..18], "transfer-encoding:")) {
            chunked = std.ascii.indexOfIgnoreCase(line[18..], "chunked") != null;
        }
    }
    if (!chunked) return .{ .status = status, .body = body };
    var out = std.ArrayList(u8).init(a);
    var at: usize = 0;
    // ответ длиннее предела обрывается посреди куска — остаётся его начало
    while (at < body.len) {
        const nl = std.mem.indexOfPos(u8, body, at, "\r\n") orelse break;
        const size_text = body[at..nl];
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, size_text[0..semi], " "), 16) catch return error.Protocol;
        if (n == 0) break;
        const have = @min(n, body.len - (nl + 2));
        try out.appendSlice(body[nl + 2 ..][0..have]);
        at = nl + 2 + n + 2;
    }
    return .{ .status = status, .body = out.items };
}

/// GET `path` у `hostport`. Память ответа — из `a`. `public_only` — не
/// соединяться с адресами этой машины и внутренних сетей.
pub fn get(a: std.mem.Allocator, https: bool, hostport: []const u8, path: []const u8, public_only: bool) Error!Response {
    if (https and !tls_ok) return error.NoTls;
    const hp = splitHostPort(hostport, if (https) 443 else 80) orelse return error.BadAddress;
    const deadline = sys.nowMs() + budget_ms;
    const list = std.net.getAddressList(a, hp.host, hp.port) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Resolve;
    defer list.deinit();
    if (list.addrs.len == 0) return error.Resolve;

    var fd: net.Socket = net.invalid;
    var why: Error = error.Connect;
    for (list.addrs) |addr| {
        if (public_only and isPrivate(addr)) {
            why = error.Private;
            continue;
        }
        fd = connect(addr, deadline) catch |e| {
            why = e;
            if (e == error.Timeout) break;
            continue;
        };
        break;
    }
    if (fd == net.invalid) return why;
    defer net.close(fd);
    const sock = Sock{ .fd = fd, .deadline = deadline };

    const request = std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: clipper-fed/1\r\nAccept: text/plain\r\nConnection: close\r\n\r\n", .{ path, hostport }) catch return error.OutOfMemory;
    const buf = a.alloc(u8, max_response) catch return error.OutOfMemory;
    var n: usize = 0;

    if (https) {
        if (!tls_ok) return error.NoTls;
        if (!bundle_loaded) {
            bundle.rescan(std.heap.page_allocator) catch return error.Tls;
            bundle_loaded = true;
        }
        var tc = std.crypto.tls.Client.init(sock, .{ .host = .{ .explicit = hp.host }, .ca = .{ .bundle = bundle } }) catch |e| return switch (e) {
            error.Timeout => error.Timeout,
            else => error.Tls,
        };
        tc.writeAll(sock, request) catch return error.Connect;
        while (n < buf.len and !complete(buf[0..n])) {
            const got = tc.read(sock, buf[n..]) catch |e| {
                if (e == error.Timeout) return error.Timeout;
                break; // сервер закрыл соединение без close_notify — разбираем, что пришло
            };
            if (got == 0) break;
            n += got;
        }
    } else {
        sock.writeAll(request) catch |e| return if (e == error.Timeout) error.Timeout else error.Connect;
        while (n < buf.len and !complete(buf[0..n])) {
            const got = sock.read(buf[n..]) catch |e| {
                if (e == error.Timeout) return error.Timeout;
                break;
            };
            if (got == 0) break;
            n += got;
        }
    }
    return parseResponse(a, buf[0..n]);
}

test "адрес сайта и внутренние сети" {
    try std.testing.expectEqualStrings("example.com", splitHostPort("example.com", 443).?.host);
    try std.testing.expectEqual(@as(u16, 8443), splitHostPort("example.com:8443", 443).?.port);
    try std.testing.expectEqualStrings("::1", splitHostPort("[::1]:3000", 80).?.host);
    try std.testing.expectEqual(@as(u16, 80), splitHostPort("[2001:db8::1]", 80).?.port);
    try std.testing.expect(splitHostPort("a:b", 80) == null);
    try std.testing.expect(splitHostPort("a:1:2", 80) == null);
    try std.testing.expect(splitHostPort("", 80) == null);
    const A = std.net.Address;
    try std.testing.expect(isPrivate(A.initIp4(.{ 127, 0, 0, 1 }, 80)));
    try std.testing.expect(isPrivate(A.initIp4(.{ 192, 168, 1, 5 }, 80)));
    try std.testing.expect(isPrivate(A.initIp4(.{ 172, 20, 1, 5 }, 80)));
    try std.testing.expect(isPrivate(A.initIp4(.{ 169, 254, 169, 254 }, 80)));
    try std.testing.expect(!isPrivate(A.initIp4(.{ 93, 184, 216, 34 }, 80)));
    try std.testing.expect(isPrivate(try A.parseIp6("::1", 80)));
    try std.testing.expect(isPrivate(try A.parseIp6("fe80::1", 80)));
    try std.testing.expect(isPrivate(try A.parseIp6("::ffff:10.0.0.1", 80)));
    try std.testing.expect(!isPrivate(try A.parseIp6("2001:db8::1", 80)));
}

test "ответ HTTP: длина и chunked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(complete(plain));
    try std.testing.expect(!complete(plain[0 .. plain.len - 1]));
    const r = try parseResponse(a, plain);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("hello", r.body);
    const ch = "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=1\r\nde\r\n0\r\n\r\n";
    try std.testing.expect(complete(ch));
    const r2 = try parseResponse(a, ch);
    try std.testing.expectEqual(@as(u16, 403), r2.status);
    try std.testing.expectEqualStrings("abcde", r2.body);
    try std.testing.expectEqualStrings("abcd", (try parseResponse(a, "HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\nff\r\nd")).body);
    try std.testing.expectError(error.Protocol, parseResponse(a, "SSH-2.0-OpenSSH\r\n\r\n"));
    try std.testing.expectEqualStrings("short", (try parseResponse(a, "HTTP/1.1 404 Not Found\r\nContent-Length: 90000\r\n\r\nshort")).body);
}
