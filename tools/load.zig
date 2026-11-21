//! Замер нагрузки (этап 9): N соединений keep-alive шлют запросы по кругу и
//! меряют время каждого ответа.
//!
//!   zig build load -- HOST PORT [-c СОЕДИНЕНИЙ] [-n ЗАПРОСОВ] [--close] ПУТЬ...
//!
//! По умолчанию 64 соединения, 100000 запросов, путь «/». `--close` — новое
//! соединение на каждый запрос. Инструмент собирается под машину сборки и
//! использует потоки; сам сервер остаётся однопоточным.

const std = @import("std");

const Shared = struct {
    host: []const u8,
    addr: std.net.Address,
    paths: []const []const u8,
    close: bool,
    left: std.atomic.Value(i64),
};

const Result = struct {
    lat_us: std.ArrayListUnmanaged(u32) = .{},
    bytes: u64 = 0,
    errors: u64 = 0,
    bad_status: u64 = 0,
};

fn connect(sh: *const Shared) ?std.net.Stream {
    return std.net.tcpConnectToAddress(sh.addr) catch null;
}

/// Читает один ответ целиком. Возвращает код ответа и число байт; null — обрыв.
fn readReply(s: std.net.Stream, buf: []u8) ?struct { u16, usize } {
    var have: usize = 0;
    const head_end = while (true) {
        if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |e| break e + 4;
        if (have == buf.len) return null;
        const n = s.read(buf[have..]) catch return null;
        if (n == 0) return null;
        have += n;
    };
    if (head_end < 12) return null;
    const status = std.fmt.parseInt(u16, buf[9..12], 10) catch return null;
    var len: usize = 0;
    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
    while (lines.next()) |l| {
        if (std.ascii.startsWithIgnoreCase(l, "content-length:")) len = std.fmt.parseInt(usize, std.mem.trim(u8, l[15..], " "), 10) catch return null;
    }
    var got = have - head_end;
    while (got < len) {
        const n = s.read(buf[0..@min(buf.len, len - got)]) catch return null;
        if (n == 0) return null;
        got += n;
    }
    return .{ status, head_end + len };
}

fn worker(gpa: std.mem.Allocator, sh: *Shared, res: *Result, id: usize) void {
    const buf = gpa.alloc(u8, 64 * 1024) catch return;
    defer gpa.free(buf);
    var req_buf: [2300]u8 = undefined;
    var stream: ?std.net.Stream = null;
    defer if (stream) |s| s.close();
    var k = id;
    var timer = std.time.Timer.start() catch return;
    while (sh.left.fetchSub(1, .monotonic) > 0) : (k += 1) {
        const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\n{s}\r\n", .{ sh.paths[k % sh.paths.len], sh.host, if (sh.close) "Connection: close\r\n" else "" }) catch continue;
        timer.reset();
        if (stream == null) stream = connect(sh);
        const s = stream orelse {
            res.errors += 1;
            std.time.sleep(std.time.ns_per_ms);
            continue;
        };
        const ok = if (s.writeAll(req)) |_| readReply(s, buf) else |_| null;
        if (ok) |r| {
            res.lat_us.append(gpa, @intCast(@min(timer.read() / 1000, std.math.maxInt(u32)))) catch {};
            res.bytes += r[1];
            if (r[0] >= 400) res.bad_status += 1;
        } else res.errors += 1;
        if (ok == null or sh.close) {
            s.close();
            stream = null;
        }
    }
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("load: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(gpa);
    if (argv.len < 3) die("нужно: HOST PORT [-c СОЕДИНЕНИЙ] [-n ЗАПРОСОВ] [--close] ПУТЬ...", .{});
    var conns: usize = 64;
    var total: i64 = 100_000;
    var close = false;
    var paths = std.ArrayList([]const u8).init(gpa);
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--close")) {
            close = true;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= argv.len) die("после {s} нужно число", .{a});
            const v = std.fmt.parseInt(u32, argv[i], 10) catch die("после {s} нужно число", .{a});
            if (v == 0) die("после {s} нужно число больше нуля", .{a});
            if (a[1] == 'c') conns = v else total = v;
        } else if (a.len > 0 and a[0] == '/') {
            try paths.append(a);
        } else die("непонятный аргумент: {s}", .{a});
    }
    if (paths.items.len == 0) try paths.append("/");
    const port = std.fmt.parseInt(u16, argv[2], 10) catch die("неверный порт: {s}", .{argv[2]});

    // Адрес выбирается один раз: имя вроде localhost даёт и ::1, и 127.0.0.1, а
    // отказ в соединении на Windows стоит около двух секунд.
    const list = std.net.getAddressList(gpa, argv[1], port) catch die("имя {s} не найдено", .{argv[1]});
    const addr = for (list.addrs) |a| {
        const s = std.net.tcpConnectToAddress(a) catch continue;
        s.close();
        break a;
    } else die("{s}:{d} не отвечает", .{ argv[1], port });

    var sh = Shared{ .host = argv[1], .addr = addr, .paths = paths.items, .close = close, .left = std.atomic.Value(i64).init(total) };
    const results = try gpa.alloc(Result, conns);
    const threads = try gpa.alloc(std.Thread, conns);
    var timer = try std.time.Timer.start();
    for (results, threads, 0..) |*r, *t, id| {
        r.* = .{};
        t.* = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, worker, .{ gpa, &sh, r, id });
    }
    for (threads) |t| t.join();
    const elapsed_ns = timer.read();

    var all = std.ArrayList(u32).init(gpa);
    var bytes: u64 = 0;
    var errors: u64 = 0;
    var bad: u64 = 0;
    for (results) |r| {
        try all.appendSlice(r.lat_us.items);
        bytes += r.bytes;
        errors += r.errors;
        bad += r.bad_status;
    }
    std.mem.sort(u32, all.items, {}, std.sort.asc(u32));
    const n = all.items.len;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const out = std.io.getStdOut().writer();
    try out.print("соединений {d}{s}, путей {d}, ответов {d}, обрывов {d}, ответов 4xx/5xx {d}\n", .{ conns, if (close) " (без keep-alive)" else "", paths.items.len, n, errors, bad });
    if (n == 0) std.process.exit(1);
    const pct = struct {
        fn at(v: []const u32, p: usize) f64 {
            return @as(f64, @floatFromInt(v[@min(v.len - 1, v.len * p / 1000)])) / 1000.0;
        }
    }.at;
    try out.print("{d:.0} запросов/с, {d:.1} МБ/с, {d:.2} с\n", .{ @as(f64, @floatFromInt(n)) / secs, @as(f64, @floatFromInt(bytes)) / secs / (1024 * 1024), secs });
    try out.print("время ответа, мс: p50 {d:.2} · p90 {d:.2} · p99 {d:.2} · p99.9 {d:.2} · наибольшее {d:.2}\n", .{ pct(all.items, 500), pct(all.items, 900), pct(all.items, 990), pct(all.items, 999), @as(f64, @floatFromInt(all.items[n - 1])) / 1000.0 });
    if (errors > 0) std.process.exit(1);
}
