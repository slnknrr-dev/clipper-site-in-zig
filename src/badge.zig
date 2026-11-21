//! Бейджи и информеры: /x/{вид}/{метод}[.svg|.png][?id=&label=&color=];
//! без расширения — JSON. PNG рисуется своим кодером (deflate из std,
//! пиксельный шрифт 3×5).

const std = @import("std");
const cp = @import("cp1251.zig");
const L = @import("ledger.zig");
const Ctx = @import("app.zig").Ctx;

pub const Kind = struct { name: []const u8, methods: []const []const u8, needs_id: bool };
pub const kinds = [_]Kind{
    .{ .name = "b", .methods = &.{ "reads", "downloads", "comments", "chapters" }, .needs_id = true },
    .{ .name = "u", .methods = &.{ "books", "pieces", "posts", "comments" }, .needs_id = true },
    .{ .name = "p", .methods = &.{"lines"}, .needs_id = true },
    .{ .name = "c", .methods = &.{"quotes"}, .needs_id = true },
    .{ .name = "f", .methods = &.{"topics"}, .needs_id = true },
    .{ .name = "s", .methods = &.{ "p", "b", "c", "d", "f", "u" }, .needs_id = false },
    .{ .name = "site", .methods = &.{ "users", "books", "online", "views", "reads" }, .needs_id = false },
};

pub const Metric = struct { label: []const u8, value: i64 };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn totalReads(c: *Ctx) i64 {
    var sum: i64 = 0;
    var it = c.db.l.scan(c.a, "b");
    while (it.next()) |e| sum += L.fieldInt(e.val, 1);
    var pit = c.app.pending.iterator();
    while (pit.next()) |e| sum += e.value_ptr[0];
    return sum;
}

pub fn metric(c: *Ctx, kind: []const u8, method: []const u8, id: i32) ?Metric {
    const d = c.db;
    const s = d.s;
    if (eq(kind, "b")) {
        const b = s.book(id) orelse return null;
        const st = c.app.stat(d, id);
        if (eq(method, "reads")) return .{ .label = "reads", .value = st.reads };
        if (eq(method, "downloads")) return .{ .label = "downloads", .value = st.downloads };
        if (eq(method, "comments")) return .{ .label = "comments", .value = @intCast(d.comments(id).len) };
        if (eq(method, "chapters")) return .{ .label = "chapters", .value = b.n_pages };
        return null;
    }
    if (eq(kind, "u")) {
        if (!d.isUser(id)) return null;
        var n: i64 = 0;
        if (eq(method, "books")) {
            for (s.books) |b| n += @intFromBool(b.author == id or (b.uploader == id and id != 0));
            return .{ .label = "books", .value = n };
        }
        if (eq(method, "pieces")) {
            for (s.pieces) |p| n += @intFromBool(p.author == id);
            return .{ .label = "poems", .value = n };
        }
        if (eq(method, "posts")) {
            for (d.allPosts()) |p| n += @intFromBool(p.author == id);
            return .{ .label = "posts", .value = n };
        }
        if (eq(method, "comments")) {
            var it = d.l.scan(c.a, "C");
            while (it.next()) |e| n += @intFromBool(L.fieldInt(e.val, 1) == id);
            return .{ .label = "comments", .value = n };
        }
        return null;
    }
    if (eq(kind, "p") and eq(method, "lines")) {
        const p = d.piece(id) orelse return null;
        return .{ .label = "lines", .value = @intCast(std.mem.count(u8, p.text, "\n") + 1) };
    }
    if (eq(kind, "c") and eq(method, "quotes")) {
        if (d.person(id) == null) return null;
        var n: i64 = 0;
        for (d.quotes()) |q| n += @intFromBool(q.person == id);
        return .{ .label = "quotes", .value = n };
    }
    if (eq(kind, "f") and eq(method, "topics")) {
        if (d.forum(id) == null) return null;
        return .{ .label = "topics", .value = @intCast(d.topics(id).len) };
    }
    if (eq(kind, "s")) {
        if (eq(method, "p")) return .{ .label = "poems", .value = @intCast(s.pieces.len) };
        if (eq(method, "b")) return .{ .label = "books", .value = @intCast(s.books.len) };
        if (eq(method, "c")) return .{ .label = "quotes", .value = @intCast(d.l.count(c.a, "Q")) };
        if (eq(method, "d")) return .{ .label = "drafts", .value = @intCast(d.l.count(c.a, "D")) };
        if (eq(method, "f")) return .{ .label = "forums", .value = @intCast(d.l.count(c.a, "F")) };
        if (eq(method, "u")) return .{ .label = "members", .value = @intCast(d.l.count(c.a, "U")) };
        return null;
    }
    if (eq(kind, "site")) {
        if (eq(method, "users")) return .{ .label = "users", .value = @intCast(d.l.count(c.a, "A") + 1) };
        if (eq(method, "books")) return .{ .label = "books", .value = @intCast(s.books.len) };
        if (eq(method, "online")) return .{ .label = "online", .value = @intCast(d.l.count(c.a, "S")) };
        if (eq(method, "views")) return .{ .label = "views", .value = @intCast(c.app.views) };
        if (eq(method, "reads")) return .{ .label = "reads", .value = totalReads(c) };
        return null;
    }
    return null;
}

const colors = .{ .{ "green", "44cc11" }, .{ "blue", "007ec6" }, .{ "red", "e05d44" }, .{ "orange", "fe7d37" }, .{ "grey", "9f9f9f" }, .{ "navy", "24375b" }, .{ "maroon", "800000" } };

/// Шесть шестнадцатеричных цифр цвета.
pub fn color(name: []const u8) [6]u8 {
    inline for (colors) |kv| if (eq(name, kv[0])) return kv[1].*;
    if (name.len == 6) {
        var ok = true;
        for (name) |ch| ok = ok and std.ascii.isHex(ch);
        if (ok) return name[0..6].*;
    }
    return "44cc11".*;
}

pub fn svg(out: *std.ArrayList(u8), label_utf8: []const u8, value: []const u8, col: [6]u8) !void {
    const chars = std.unicode.utf8CountCodepoints(label_utf8) catch label_utf8.len;
    const w1 = 6 * chars + 10;
    const w2 = 6 * value.len + 10;
    const w = out.writer();
    try w.print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"20\"><rect width=\"{d}\" height=\"20\" fill=\"#555\"/><rect x=\"{d}\" width=\"{d}\" height=\"20\" fill=\"#{s}\"/>\n<g fill=\"#fff\" font-family=\"Verdana,Arial,sans-serif\" font-size=\"11\" text-anchor=\"middle\"><text x=\"{d}{s}\" y=\"14\">", .{ w1 + w2, w1, w1, w2, col, w1 / 2, if (w1 % 2 == 1) ".5" else "" });
    for (label_utf8) |ch| switch (ch) {
        '&' => try out.appendSlice("&amp;"),
        '<' => try out.appendSlice("&lt;"),
        '>' => try out.appendSlice("&gt;"),
        else => try out.append(ch),
    };
    try w.print("</text><text x=\"{d}{s}\" y=\"14\">{s}</text></g></svg>", .{ w1 + w2 / 2, if (w2 % 2 == 1) ".5" else "", value });
}

// ───────────── PNG: шрифт 3×5, масштаб 2 ─────────────

fn glyph(ch: u8) *const [15]u8 {
    return switch (ch) {
        'A' => "010101111101101",
        'B' => "110101110101110",
        'C' => "011100100100011",
        'D' => "110101101101110",
        'E' => "111100110100111",
        'F' => "111100110100100",
        'G' => "011100101101011",
        'H' => "101101111101101",
        'I' => "111010010010111",
        'J' => "001001001101010",
        'K' => "101101110101101",
        'L' => "100100100100111",
        'M' => "101111111101101",
        'N' => "110101101101101",
        'O' => "010101101101010",
        'P' => "110101110100100",
        'Q' => "010101101110011",
        'R' => "110101110101101",
        'S' => "011100010001110",
        'T' => "111010010010010",
        'U' => "101101101101111",
        'V' => "101101101101010",
        'W' => "101101111111101",
        'X' => "101101010101101",
        'Y' => "101101010010010",
        'Z' => "111001010100111",
        '0' => "111101101101111",
        '1' => "010110010010111",
        '2' => "110001010100111",
        '3' => "110001010001110",
        '4' => "101101111001001",
        '5' => "111100110001110",
        '6' => "011100111101111",
        '7' => "111001010010010",
        '8' => "111101111101111",
        '9' => "111101111001110",
        ' ' => "000000000000000",
        '.' => "000000000000010",
        '-' => "000000111000000",
        '/' => "001001010100100",
        ':' => "000010000010000",
        '%' => "101001010100101",
        else => "110001010000010",
    };
}

fn chunk(out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(&len);
    try out.appendSlice(kind);
    try out.appendSlice(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    std.mem.writeInt(u32, &len, crc.final(), .big);
    try out.appendSlice(&len);
}

/// Подпись и значение — латиница, цифры и знаки шрифта; остальное рисуется как «?».
pub fn png(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, value: []const u8, col: [6]u8) !void {
    const scale = 2;
    const gw = 4 * scale;
    const height = 20;
    const w1 = label.len * gw + 8;
    const w2 = value.len * gw + 8;
    const width = w1 + w2;
    var bg2: [3]u8 = undefined;
    _ = std.fmt.hexToBytes(&bg2, &col) catch {
        bg2 = .{ 0x44, 0xcc, 0x11 };
    };
    const stride = width * 3 + 1;
    const px = try a.alloc(u8, height * stride);
    @memset(px, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const o = y * stride + 1 + x * 3;
            const bg: [3]u8 = if (x < w1) .{ 0x55, 0x55, 0x55 } else bg2;
            @memcpy(px[o..][0..3], &bg);
        }
    }
    inline for (.{ label, value }, .{ 4, w1 + 4 }) |s, x0| {
        for (s, 0..) |raw, i| {
            const g = glyph(std.ascii.toUpper(raw));
            for (0..5) |r| for (0..3) |k| {
                if (g[r * 3 + k] != '1') continue;
                for (0..scale) |dy| for (0..scale) |dx| {
                    const o = (5 + r * scale + dy) * stride + 1 + (x0 + i * gw + k * scale + dx) * 3;
                    @memset(px[o..][0..3], 255);
                };
            };
        }
    }
    try out.appendSlice("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 };
    try chunk(out, "IHDR", &ihdr);
    var z = std.ArrayList(u8).init(a);
    var in = std.io.fixedBufferStream(px);
    try std.compress.zlib.compress(in.reader(), z.writer(), .{});
    try chunk(out, "IDAT", z.items);
    try chunk(out, "IEND", "");
}

fn jsonString(out: *std.ArrayList(u8), utf8: []const u8) !void {
    try out.append('"');
    for (utf8) |ch| switch (ch) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        0...9, 11...0x1f => try out.writer().print("\\u{x:0>4}", .{ch}),
        else => try out.append(ch),
    };
    try out.append('"');
}

pub fn serve(c: *Ctx, kind: []const u8, file: []const u8) void {
    if (!c.featureOn(.badges)) {
        c.status = 403;
        return c.send("text/plain; charset=utf-8", "badges disabled");
    }
    const dot = std.mem.indexOfScalar(u8, file, '.');
    const method = if (dot) |i| file[0..i] else file;
    const ext = if (dot) |i| file[i + 1 ..] else "";
    if (method.len == 0 or (ext.len > 0 and !eq(ext, "svg") and !eq(ext, "png"))) return c.notFound();
    for (method) |ch| if (!std.ascii.isLower(ch)) return c.notFound();
    const id = std.math.cast(i32, c.qInt("id")) orelse 0;
    const m = metric(c, kind, method, id) orelse return c.notFound();
    const label_q = c.q("label");
    const label = if (label_q.len > 0) label_q[0..@min(label_q.len, 24)] else m.label;
    const col = color(c.q("color"));
    var vb: [24]u8 = undefined;
    const value = std.fmt.bufPrint(&vb, "{d}", .{m.value}) catch "0";
    c.reply.header("Cache-Control: no-cache", .{});
    c.reply.header("Access-Control-Allow-Origin: *", .{});
    var out = std.ArrayList(u8).init(c.a);
    const label_utf8 = cp.toUtf8Alloc(c.a, label) catch "";
    if (eq(ext, "svg")) {
        svg(&out, label_utf8, value, col) catch return c.fail(500, "");
        return c.send("image/svg+xml", out.items);
    }
    if (eq(ext, "png")) {
        png(c.a, &out, label, value, col) catch return c.fail(500, "");
        return c.send("image/png", out.items);
    }
    json(&out, kind, method, id, label_utf8, m.value) catch return c.fail(500, "");
    c.send("application/json;charset=utf-8", out.items);
}

fn json(out: *std.ArrayList(u8), kind: []const u8, method: []const u8, id: i32, label_utf8: []const u8, value: i64) !void {
    const w = out.writer();
    try out.appendSlice("{\"kind\":");
    try jsonString(out, kind);
    try out.appendSlice(",\"method\":");
    try jsonString(out, method);
    try out.appendSlice(",\"id\":");
    if (id != 0) try w.print("{d}", .{id}) else try out.appendSlice("null");
    try out.appendSlice(",\"label\":");
    try jsonString(out, label_utf8);
    try w.print(",\"value\":{d}}}", .{value});
}

test "png и svg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = std.ArrayList(u8).init(a);
    try png(a, &out, "reads", "17", color("blue"));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x89PNG\r\n\x1a\n"));
    try std.testing.expectEqual(@as(u32, 5 * 8 + 8 + 2 * 8 + 8), std.mem.readInt(u32, out.items[16..20], .big));
    try std.testing.expect(std.mem.endsWith(u8, out.items, "IEND\xae\x42\x60\x82"));
    // IDAT распаковывается в 20 строк пикселей
    const idat_len = std.mem.readInt(u32, out.items[33..37], .big);
    var in = std.io.fixedBufferStream(out.items[41..][0..idat_len]);
    var raw = std.ArrayList(u8).init(a);
    try std.compress.zlib.decompress(in.reader(), raw.writer());
    try std.testing.expectEqual(@as(usize, 20 * (72 * 3 + 1)), raw.items.len);
    out.clearRetainingCapacity();
    try svg(&out, "чтений", "5", color("zz"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "width=\"62\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "#44cc11") != null);
}
