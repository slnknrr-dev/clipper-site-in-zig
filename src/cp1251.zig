//! windows-1251. Весь текст внутри сервера — в этой кодировке: шаблоны и
//! строки исходников перекодируются при компиляции (`lit`), формы и адреса
//! приходят уже в ней (страницы отданы в windows-1251), а UTF-8 появляется
//! только на границах: файлы книг, экспорт (fb2, epub, txt), JSON.

const std = @import("std");
const t9n = @import("t9n.zig");

/// 0x80…0xBF → Unicode (0xC0…0xFF — это U+0410…U+044F).
const high = [64]u16{
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
};

pub fn toUnicode(c: u8) u21 {
    if (c < 0x80) return c;
    if (c >= 0xC0) return 0x0410 + @as(u21, c - 0xC0);
    return high[c - 0x80];
}

pub fn fromUnicode(u: u21) ?u8 {
    if (u < 0x80) return @intCast(u);
    if (u >= 0x0410 and u <= 0x044F) return @intCast(0xC0 + (u - 0x0410));
    for (high, 0..) |h, i| if (h == u) return @intCast(0x80 + i);
    return null;
}

pub fn lower(c: u8) u8 {
    return switch (c) {
        'A'...'Z' => c + 32,
        0xC0...0xDF => c + 32,
        0xA8 => 0xB8,
        else => c,
    };
}

pub fn upper(c: u8) u8 {
    return switch (c) {
        'a'...'z' => c - 32,
        0xE0...0xFF => c - 32,
        0xB8 => 0xA8,
        else => c,
    };
}

/// Один символ UTF-8 из `s[i..]`: код и длина. Битая последовательность — U+FFFD, 1 байт.
pub fn utf8Next(s: []const u8, i: usize) struct { u21, usize } {
    const b = s[i];
    if (b < 0x80) return .{ b, 1 };
    const n: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else return .{ 0xFFFD, 1 };
    if (i + n > s.len) return .{ 0xFFFD, 1 };
    var u: u21 = b & (@as(u8, 0xFF) >> @intCast(n + 1));
    for (s[i + 1 .. i + n]) |x| {
        if (x & 0xC0 != 0x80) return .{ 0xFFFD, 1 };
        u = (u << 6) | (x & 0x3F);
    }
    return .{ u, n };
}

fn digits(u: u21) usize {
    var n: usize = 1;
    var v = u / 10;
    while (v > 0) : (v /= 10) n += 1;
    return n;
}

/// Сколько байт займёт `utf8` в windows-1251. Чего в кодировке нет, пишется
/// как `&#N;` (entity = true, для HTML) или как `?`.
pub fn encodedLen(utf8: []const u8, entity: bool) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const u, const l = utf8Next(utf8, i);
        i += l;
        n += if (fromUnicode(u) != null) 1 else if (entity) 3 + digits(u) else 1;
    }
    return n;
}

pub fn encode(dst: []u8, utf8: []const u8, entity: bool) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const u, const l = utf8Next(utf8, i);
        i += l;
        if (fromUnicode(u)) |c| {
            dst[n] = c;
            n += 1;
        } else if (entity) {
            const d = digits(u);
            dst[n] = '&';
            dst[n + 1] = '#';
            var v = u;
            var k = d;
            while (k > 0) : (k -= 1) {
                dst[n + 1 + k] = '0' + @as(u8, @intCast(v % 10));
                v /= 10;
            }
            dst[n + 2 + d] = ';';
            n += 3 + d;
        } else {
            dst[n] = '?';
            n += 1;
        }
    }
    return n;
}

fn Converted(comptime utf8: []const u8, comptime entity: bool) type {
    return struct {
        const v = blk: {
            @setEvalBranchQuota(utf8.len * 400 + 10000);
            var buf: [encodedLen(utf8, entity)]u8 = undefined;
            _ = encode(&buf, utf8, entity);
            const final = buf;
            break :blk final;
        };
    };
}

/// Строка исходника (UTF-8) → windows-1251 при компиляции, для HTML:
/// чего в кодировке нет, становится `&#N;`. Здесь же строка переводится на
/// язык сборки (`-Dlang`, см. t9n.zig).
pub fn lit(comptime utf8: []const u8) []const u8 {
    return &Converted(t9n.tr(utf8), true).v;
}

/// То же, но без `&#N;`: для текста, который не HTML (данные, заголовки файлов).
pub fn text(comptime utf8: []const u8) []const u8 {
    return &Converted(t9n.tr(utf8), false).v;
}

pub fn encodeAlloc(a: std.mem.Allocator, utf8: []const u8) ![]u8 {
    const out = try a.alloc(u8, encodedLen(utf8, false));
    _ = encode(out, utf8, false);
    return out;
}

pub fn utf8Len(cp: []const u8) usize {
    var n: usize = 0;
    for (cp) |c| {
        const u = toUnicode(c);
        n += if (u < 0x80) 1 else if (u < 0x800) @as(usize, 2) else 3;
    }
    return n;
}

pub fn toUtf8(dst: []u8, cp: []const u8) usize {
    var n: usize = 0;
    for (cp) |c| {
        const u = toUnicode(c);
        if (u < 0x80) {
            dst[n] = @intCast(u);
            n += 1;
        } else if (u < 0x800) {
            dst[n] = @intCast(0xC0 | (u >> 6));
            dst[n + 1] = @intCast(0x80 | (u & 0x3F));
            n += 2;
        } else {
            dst[n] = @intCast(0xE0 | (u >> 12));
            dst[n + 1] = @intCast(0x80 | ((u >> 6) & 0x3F));
            dst[n + 2] = @intCast(0x80 | (u & 0x3F));
            n += 3;
        }
    }
    return n;
}

pub fn toUtf8Alloc(a: std.mem.Allocator, cp: []const u8) ![]u8 {
    const out = try a.alloc(u8, utf8Len(cp));
    _ = toUtf8(out, cp);
    return out;
}

/// Похоже ли на UTF-8 с не-ASCII символами: тогда значение из адреса набрано
/// руками или пришло с чужой страницы, и его надо перекодировать.
pub fn looksUtf8(s: []const u8) bool {
    var multi = false;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        const u, const l = utf8Next(s, i);
        if (u == 0xFFFD or l == 1) return false;
        multi = true;
        i += l;
    }
    return multi;
}

/// Поиск без учёта регистра (латиница и кириллица).
pub fn indexOfFold(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and lower(hay[i + k]) == lower(needle[k])) k += 1;
        if (k == needle.len) return i;
    }
    return null;
}

pub fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

test "туда и обратно" {
    const s = "Тамань — самый скверный городишко… №1 «ёЁ»";
    var buf: [128]u8 = undefined;
    const n = encode(&buf, s, false);
    try std.testing.expectEqual(encodedLen(s, false), n);
    var back: [256]u8 = undefined;
    const m = toUtf8(&back, buf[0..n]);
    try std.testing.expectEqualStrings(s, back[0..m]);
    try std.testing.expectEqualStrings("a&#8594;b", lit("a→b"));
    try std.testing.expect(looksUtf8("Зри"));
    try std.testing.expect(!looksUtf8(text("Зри")));
    try std.testing.expect(indexOfFold(text("Жизнь Армейского"), text("армейского")).? == 6);
}
