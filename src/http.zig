//! HTTP/1.x: строгий разбор заголовка запроса, параметры адреса, формы
//! (urlencoded и multipart), cookies, даты. Чистые функции над срезами:
//! ничего не выделяют, кроме как из переданного распределителя запроса.

const std = @import("std");
const cp = @import("cp1251.zig");

pub const limits = struct {
    pub const head_bytes = 8192;
    pub const target_bytes = 2048;
    pub const header_fields = 64;
    pub const form_body = 64 * 1024;
    pub const upload_body = 50 * 1024 * 1024;
    /// Запись для /v (аудиокнига часами): тело уходит во временный файл.
    pub const voice_body = 200 * 1024 * 1024;
    pub const picture_body = 2 * 1024 * 1024 + 64 * 1024;
};

pub const Method = enum { GET, HEAD, POST };

pub const Request = struct {
    method: Method,
    /// Срезы указывают в буфер соединения.
    target: []const u8,
    path: []const u8,
    query: []const u8,
    http10: bool,
    keep_alive: bool,
    content_length: u64,
    cookie: []const u8 = "",
    content_type: []const u8 = "",
    user_agent: []const u8 = "",
    host: []const u8 = "",
    range: []const u8 = "",
    if_none_match: []const u8 = "",
    if_modified_since: []const u8 = "",
    /// Запрос пришёл через обратный прокси (X-Forwarded-For, X-Real-IP, Forwarded, Via):
    /// адрес соединения — адрес прокси, а не посетителя.
    proxied: bool = false,
    head_len: usize,
};

pub const Parsed = union(enum) { incomplete, fail: u16, ok: Request };

fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

pub fn parse(buf: []const u8) Parsed {
    const end_opt = std.mem.indexOf(u8, buf, "\r\n\r\n");
    const scan_to = if (end_opt) |e| e + 2 else buf.len;
    for (buf[0..scan_to], 0..) |c, i| {
        if (c == '\n' and (i == 0 or buf[i - 1] != '\r')) return .{ .fail = 400 };
        if (c == 0) return .{ .fail = 400 };
    }
    const end = end_opt orelse return if (buf.len >= limits.head_bytes) .{ .fail = 431 } else .incomplete;
    const head_len = end + 4;
    if (head_len > limits.head_bytes) return .{ .fail = 431 };

    var lines = std.mem.splitSequence(u8, buf[0..end], "\r\n");
    const line = lines.first();
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .fail = 400 };
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return .{ .fail = 400 };
    if (std.mem.indexOfScalarPos(u8, line, sp2 + 1, ' ') != null) return .{ .fail = 400 };
    const method_s = line[0..sp1];
    const target = line[sp1 + 1 .. sp2];
    const version_s = line[sp2 + 1 ..];
    if (!isToken(method_s) or target.len == 0) return .{ .fail = 400 };
    const http10 = if (std.mem.eql(u8, version_s, "HTTP/1.1")) false else if (std.mem.eql(u8, version_s, "HTTP/1.0")) true else if (std.mem.startsWith(u8, version_s, "HTTP/")) return .{ .fail = 505 } else return .{ .fail = 400 };
    const method = std.meta.stringToEnum(Method, method_s) orelse return .{ .fail = 405 };
    if (target.len > limits.target_bytes) return .{ .fail = 414 };
    if (target[0] != '/') return .{ .fail = 400 };
    for (target) |c| if (c <= 0x20 or c == 0x7F) return .{ .fail = 400 };

    const qm = std.mem.indexOfScalar(u8, target, '?');
    var req = Request{
        .method = method,
        .target = target,
        .path = if (qm) |q| target[0..q] else target,
        .query = if (qm) |q| target[q + 1 ..] else "",
        .http10 = http10,
        .keep_alive = !http10,
        .content_length = 0,
        .head_len = head_len,
    };
    if (!validPercent(req.query)) return .{ .fail = 400 };

    var fields: usize = 0;
    var hosts: usize = 0;
    var has_len = false;
    while (lines.next()) |h| {
        fields += 1;
        if (fields > limits.header_fields) return .{ .fail = 431 };
        if (h.len == 0 or h[0] == ' ' or h[0] == '\t') return .{ .fail = 400 };
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse return .{ .fail = 400 };
        const name = h[0..colon];
        if (!isToken(name)) return .{ .fail = 400 };
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            hosts += 1;
            req.host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (has_len) return .{ .fail = 400 };
            has_len = true;
            if (value.len == 0 or value.len > 12) return .{ .fail = 400 };
            for (value) |c| if (c < '0' or c > '9') return .{ .fail = 400 };
            req.content_length = std.fmt.parseInt(u64, value, 10) catch return .{ .fail = 400 };
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return .{ .fail = 501 };
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.indexOfIgnoreCase(value, "close") != null) req.keep_alive = false;
            if (std.ascii.indexOfIgnoreCase(value, "keep-alive") != null) req.keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "cookie")) {
            req.cookie = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            req.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "user-agent")) {
            req.user_agent = value;
        } else if (std.ascii.eqlIgnoreCase(name, "range")) {
            req.range = value;
        } else if (std.ascii.eqlIgnoreCase(name, "if-none-match")) {
            req.if_none_match = value;
        } else if (std.ascii.eqlIgnoreCase(name, "if-modified-since")) {
            req.if_modified_since = value;
        } else if (std.ascii.eqlIgnoreCase(name, "x-forwarded-for") or std.ascii.eqlIgnoreCase(name, "x-real-ip") or
            std.ascii.eqlIgnoreCase(name, "forwarded") or std.ascii.eqlIgnoreCase(name, "via"))
        {
            req.proxied = true;
        }
    }
    if (hosts > 1 or (!http10 and hosts == 0)) return .{ .fail = 400 };
    if (method != .POST and req.content_length > 0) return .{ .fail = 400 };
    if (method == .POST and !has_len) return .{ .fail = 411 };
    return .{ .ok = req };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn validPercent(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') continue;
        if (i + 2 >= s.len) return false;
        if (hexVal(s[i + 1]) == null or hexVal(s[i + 2]) == null) return false;
        i += 2;
    }
    return true;
}

/// Раскодирует `+` и `%XX`. Битый `%` остаётся как есть.
pub fn urlDecode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
        } else if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                out[n] = hi.? * 16 + lo.?;
                i += 2;
            } else out[n] = '%';
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// Значение поля: перевод в windows-1251, если это UTF-8; без \r и управляющих.
pub fn cleanText(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const src = if (cp.looksUtf8(raw)) try cp.encodeAlloc(a, raw) else try a.dupe(u8, raw);
    var n: usize = 0;
    for (src) |c| {
        if (c == '\r') continue;
        src[n] = if (c == '\t') ' ' else if (c < 0x20 and c != '\n') ' ' else c;
        n += 1;
    }
    return src[0..n];
}

/// Параметр адреса: первое вхождение, раскодированное. null — параметра нет.
pub fn param(a: std.mem.Allocator, query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = urlDecode(a, if (eq < pair.len) pair[eq + 1 ..] else "") catch return null;
        return cleanText(a, raw) catch null;
    }
    return null;
}

pub fn cookie(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (p.len > name.len and p[name.len] == '=' and std.mem.startsWith(u8, p, name)) return p[name.len + 1 ..];
    }
    return null;
}

pub const Field = struct {
    name: []const u8,
    value: []const u8,
    filename: ?[]const u8 = null,
    ctype: []const u8 = "",
};

pub const Form = struct {
    fields: []const Field = &.{},

    /// Значение без пробелов по краям; нет поля — пустая строка.
    pub fn get(f: Form, name: []const u8) []const u8 {
        return std.mem.trim(u8, f.raw(name), " \n");
    }

    pub fn raw(f: Form, name: []const u8) []const u8 {
        for (f.fields) |x| if (x.filename == null and std.mem.eql(u8, x.name, name)) return x.value;
        return "";
    }

    pub fn file(f: Form, name: []const u8) ?Field {
        for (f.fields) |x| if (x.filename != null and std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    pub fn on(f: Form, name: []const u8) bool {
        return std.mem.eql(u8, f.get(name), "1");
    }

    pub fn int(f: Form, name: []const u8) ?i64 {
        return std.fmt.parseInt(i64, f.get(name), 10) catch null;
    }
};

pub fn parseForm(a: std.mem.Allocator, content_type: []const u8, body: []const u8) !Form {
    var list = std.ArrayList(Field).init(a);
    if (std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
        const bi = std.ascii.indexOfIgnoreCase(content_type, "boundary=") orelse return error.BadForm;
        var boundary = std.mem.trim(u8, content_type[bi + 9 ..], " ");
        if (std.mem.indexOfScalar(u8, boundary, ';')) |sc| boundary = boundary[0..sc];
        boundary = std.mem.trim(u8, boundary, "\"");
        if (boundary.len == 0 or boundary.len > 200) return error.BadForm;
        const delim = try std.fmt.allocPrint(a, "--{s}", .{boundary});
        var pos = std.mem.indexOf(u8, body, delim) orelse return error.BadForm;
        while (true) {
            pos += delim.len;
            if (pos + 2 > body.len) break;
            if (body[pos] == '-' and body[pos + 1] == '-') break;
            if (body[pos] != '\r' or body[pos + 1] != '\n') return error.BadForm;
            pos += 2;
            const hend = std.mem.indexOfPos(u8, body, pos, "\r\n\r\n") orelse return error.BadForm;
            const head = body[pos..hend];
            const data_from = hend + 4;
            const next = std.mem.indexOfPos(u8, body, data_from, delim) orelse return error.BadForm;
            if (next < data_from + 2 or body[next - 2] != '\r' or body[next - 1] != '\n') return error.BadForm;
            const data = body[data_from .. next - 2];
            var fld = Field{ .name = "", .value = data };
            var hl = std.mem.splitSequence(u8, head, "\r\n");
            while (hl.next()) |h| {
                if (std.ascii.startsWithIgnoreCase(h, "content-disposition:")) {
                    fld.name = attr(h, "name") orelse "";
                    fld.filename = attr(h, "filename");
                } else if (std.ascii.startsWithIgnoreCase(h, "content-type:")) {
                    fld.ctype = std.mem.trim(u8, h[13..], " ");
                }
            }
            if (fld.filename == null) fld.value = try cleanText(a, data);
            if (list.items.len >= 512) return error.BadForm;
            try list.append(fld);
            pos = next;
        }
    } else {
        var it = std.mem.splitScalar(u8, body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const name = try urlDecode(a, pair[0..eq]);
            const val = try cleanText(a, try urlDecode(a, if (eq < pair.len) pair[eq + 1 ..] else ""));
            if (list.items.len >= 512) return error.BadForm;
            try list.append(.{ .name = name, .value = val });
        }
    }
    return .{ .fields = list.items };
}

/// `name="value"` из строки заголовка части multipart.
fn attr(h: []const u8, comptime name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, h, from, name ++ "=\"")) |i| {
        // «name» не должен быть хвостом «filename»
        if (i > 0 and h[i - 1] != ' ' and h[i - 1] != ';') {
            from = i + 1;
            continue;
        }
        const start = i + name.len + 2;
        const end = std.mem.indexOfScalarPos(u8, h, start, '"') orelse return null;
        return h[start..end];
    }
    return null;
}

// ───────────── даты ─────────────

const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const Civil = struct { year: u32, month: u8, day: u8, hour: u8, min: u8, sec: u8, wday: u8 };

pub fn civil(ts: i64) Civil {
    const t: u64 = @intCast(@max(ts, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = t };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .min = ds.getMinutesIntoHour(),
        .sec = ds.getSecondsIntoMinute(),
        .wday = @intCast((t / 86400) % 7),
    };
}

/// "Sun, 06 Nov 1994 08:49:37 GMT"
pub fn httpDate(buf: *[29]u8, ts: i64) []const u8 {
    const c = civil(ts);
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ days[c.wday], c.day, months[c.month - 1], c.year, c.hour, c.min, c.sec }) catch unreachable;
}

/// "2003-04-02"
pub fn isoDate(buf: *[10]u8, ts: i64) []const u8 {
    const c = civil(ts);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day }) catch unreachable;
}

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        206 => "Partial Content",
        303 => "See Other",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "Internal Server Error",
    };
}

/// Один диапазон `bytes=a-b`, `a-`, `-n`. null — заголовка нет или он не разобран
/// (тогда отдаётся весь файл); error.Unsatisfiable — диапазон за концом.
pub fn parseRange(h: []const u8, len: u64) error{Unsatisfiable}!?struct { u64, u64 } {
    if (!std.mem.startsWith(u8, h, "bytes=")) return null;
    const spec = h[6..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const a = spec[0..dash];
    const b = spec[dash + 1 ..];
    if (a.len == 0) {
        const n = std.fmt.parseInt(u64, b, 10) catch return null;
        if (n == 0 or len == 0) return error.Unsatisfiable; // у пустого тела нет последних байтов
        return .{ len -| n, len };
    }
    const from = std.fmt.parseInt(u64, a, 10) catch return null;
    if (from >= len) return error.Unsatisfiable;
    if (b.len == 0) return .{ from, len };
    const to = std.fmt.parseInt(u64, b, 10) catch return null;
    if (to < from) return null;
    return .{ from, @min(to + 1, len) };
}

test "разбор запроса" {
    const ok = parse("GET /b/2?t=samlib HTTP/1.1\r\nHost: x\r\nCookie: sid=abc; csrf=def\r\n\r\n");
    try std.testing.expect(ok == .ok);
    try std.testing.expectEqualStrings("/b/2", ok.ok.path);
    try std.testing.expectEqualStrings("def", cookie(ok.ok.cookie, "csrf").?);
    try std.testing.expect(parse("GET / HTTP/1.1\r\n\r\n").fail == 400); // нет Host
    try std.testing.expect(parse("GET / HTTP/2.0\r\nHost: x\r\n\r\n").fail == 505);
    try std.testing.expect(parse("PUT / HTTP/1.1\r\nHost: x\r\n\r\n").fail == 405);
    try std.testing.expect(parse("POST / HTTP/1.1\r\nHost: x\r\n\r\n").fail == 411);
    try std.testing.expect(parse("GET / HTTP/1.1\nHost: x\r\n\r\n").fail == 400);
    try std.testing.expect(parse("GET /?q=%zz HTTP/1.1\r\nHost: x\r\n\r\n").fail == 400);
    try std.testing.expect(parse("GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n").fail == 501);
    try std.testing.expect(parse("GET / HTTP/1.1\r\nHo") == .incomplete);
}

test "формы" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try parseForm(a, "application/x-www-form-urlencoded", "a=1&b=x+y%21&id=3&id=4");
    try std.testing.expectEqualStrings("x y!", f.get("b"));
    try std.testing.expect(f.int("id").? == 3);
    const body = "--XX\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nT\r\n--XX\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nline1\r\nline2\r\n--XX--\r\n";
    const m = try parseForm(a, "multipart/form-data; boundary=XX", body);
    try std.testing.expectEqualStrings("T", m.get("title"));
    try std.testing.expectEqualStrings("line1\r\nline2", m.file("file").?.value);
    try std.testing.expectError(error.BadForm, parseForm(a, "multipart/form-data; boundary=XX", "--XX\r\nfoo"));
    try std.testing.expectEqualStrings("a b", param(a, "q=a+b&t=x", "q").?);
}
