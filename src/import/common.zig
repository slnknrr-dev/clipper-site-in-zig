//! Общее для разборщиков загружаемых книг (EPUB, PDF): распаковка с пределом,
//! чтение ZIP, перевод символов в windows-1251, текст из HTML.
//!
//! Вход враждебен: ни одного обращения к байтам без проверки границ, каждый
//! цикл продвигается, всё распакованное считается против общего предела.

const std = @import("std");
const cp = @import("../cp1251.zig");

pub const Error = error{ OutOfMemory, TooBig, Damaged };

/// Сколько байт разборщик вправе распаковать и выделить под текст.
pub const Budget = struct {
    left: usize,

    pub fn take(b: *Budget, n: usize) error{TooBig}!void {
        if (n > b.left) return error.TooBig;
        b.left -= n;
    }
};

pub const Container = enum { raw, zlib };

/// Распаковывает deflate. Оборванный или испорченный поток отдаёт то, что
/// успел распаковать (`strict = false`), — так читают PDF.
pub fn inflate(a: std.mem.Allocator, container: Container, data: []const u8, budget: *Budget, strict: bool) Error![]u8 {
    var out = std.ArrayList(u8).init(a);
    var in = std.io.fixedBufferStream(data);
    var chunk: [16 * 1024]u8 = undefined;
    switch (container) {
        inline else => |kind| {
            var d = if (kind == .raw) std.compress.flate.decompressor(in.reader()) else std.compress.zlib.decompressor(in.reader());
            while (true) {
                const n = d.reader().read(&chunk) catch {
                    if (strict) return error.Damaged;
                    break;
                };
                if (n == 0) break;
                try budget.take(n);
                try out.appendSlice(chunk[0..n]);
            }
        },
    }
    return out.items;
}

// ───────────── ZIP ─────────────

pub const Zip = struct {
    bytes: []const u8,
    entries: []const Entry,

    pub const Entry = struct { name: []const u8, method: u16, csize: u32, size: u32, offset: u32 };

    fn rd(bytes: []const u8, at: usize, comptime T: type) ?T {
        if (at > bytes.len or bytes.len - at < @sizeOf(T)) return null;
        return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
    }

    /// Читает оглавление архива (без ZIP64 и без шифрования).
    pub fn open(a: std.mem.Allocator, bytes: []const u8) Error!Zip {
        if (bytes.len < 22) return error.Damaged;
        // запись «конец оглавления» — в последних 64 КБ
        var at: usize = bytes.len - 22;
        const lowest = bytes.len -| (22 + 65535);
        const eocd = while (true) : (at -= 1) {
            if (rd(bytes, at, u32) == 0x06054b50) break at;
            if (at == lowest) return error.Damaged;
        };
        const count = rd(bytes, eocd + 10, u16) orelse return error.Damaged;
        var pos: usize = rd(bytes, eocd + 16, u32) orelse return error.Damaged;
        var list = std.ArrayList(Entry).init(a);
        for (0..count) |_| {
            if (rd(bytes, pos, u32) != 0x02014b50) break;
            const flags = rd(bytes, pos + 8, u16) orelse break;
            const method = rd(bytes, pos + 10, u16) orelse break;
            const csize = rd(bytes, pos + 20, u32) orelse break;
            const size = rd(bytes, pos + 24, u32) orelse break;
            const nlen: usize = rd(bytes, pos + 28, u16) orelse break;
            const xlen: usize = rd(bytes, pos + 30, u16) orelse break;
            const clen: usize = rd(bytes, pos + 32, u16) orelse break;
            const offset = rd(bytes, pos + 42, u32) orelse break;
            if (pos + 46 + nlen > bytes.len) break;
            const name = bytes[pos + 46 ..][0..nlen];
            pos += 46 + nlen + xlen + clen;
            if (flags & 1 != 0 or csize == 0xFFFFFFFF or offset == 0xFFFFFFFF) continue; // шифрованное или ZIP64
            try list.append(.{ .name = name, .method = method, .csize = csize, .size = size, .offset = offset });
        }
        return .{ .bytes = bytes, .entries = list.items };
    }

    pub fn find(z: *const Zip, name: []const u8) ?Entry {
        for (z.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        for (z.entries) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e;
        return null;
    }

    pub fn read(z: *const Zip, a: std.mem.Allocator, e: Entry, budget: *Budget) Error![]const u8 {
        const at: usize = e.offset;
        if (rd(z.bytes, at, u32) != 0x04034b50) return error.Damaged;
        const nlen: usize = rd(z.bytes, at + 26, u16) orelse return error.Damaged;
        const xlen: usize = rd(z.bytes, at + 28, u16) orelse return error.Damaged;
        const from = at + 30 + nlen + xlen;
        if (from > z.bytes.len or z.bytes.len - from < e.csize) return error.Damaged;
        const data = z.bytes[from..][0..e.csize];
        return switch (e.method) {
            0 => data,
            8 => try inflate(a, .raw, data, budget, true),
            else => error.Damaged,
        };
    }
};

// ───────────── символы ─────────────

/// Символ Юникода в windows-1251. Чего в кодировке нет — ближайшая замена или «?».
pub fn fromUnicode(u: u21) []const u8 {
    if (u < 0x80) return @as(*const [1]u8, @ptrCast(&ascii[u]));
    if (cp.fromUnicode(u)) |c| return @as(*const [1]u8, @ptrCast(&high[c - 0x80]));
    return switch (u) {
        0x2010, 0x2011, 0x2212, 0x2043 => "-",
        // буквы старой орфографии, которых в кодировке нет
        0x0462 => "\xC5",
        0x0463 => "\xE5",
        0x0472 => "\xD4",
        0x0473 => "\xF4",
        0x0474 => "\xC8",
        0x0475 => "\xE8",
        0x2012, 0x2015 => "\x96",
        0x2002...0x200A, 0x202F, 0x205F, 0x3000 => " ",
        0x200B...0x200F, 0x2028...0x202E, 0x2060, 0xFEFF, 0x0300...0x036F => "", // невидимые и надстрочные знаки
        0x2032 => "'",
        0x2033 => "\"",
        0x02BC, 0x02B9 => "'",
        0xFB00 => "ff",
        0xFB01 => "fi",
        0xFB02 => "fl",
        0xFB03 => "ffi",
        0xFB04 => "ffl",
        0x00C0...0x00C5 => "A",
        0x00C8...0x00CB => "E",
        0x00CC...0x00CF => "I",
        0x00D2...0x00D6 => "O",
        0x00D9...0x00DC => "U",
        0x00E0...0x00E5 => "a",
        0x00E8...0x00EB => "e",
        0x00EC...0x00EF => "i",
        0x00F2...0x00F6 => "o",
        0x00F9...0x00FC => "u",
        0x00E7 => "c",
        0x00C7 => "C",
        0x00F1 => "n",
        0x00D1 => "N",
        0x00DF => "ss",
        0x00D7 => "x",
        0x2248 => "~",
        0x2264 => "<=",
        0x2265 => ">=",
        0x00BD => "1/2",
        0x00BC => "1/4",
        0x00BE => "3/4",
        else => "?",
    };
}

/// Один байт windows-1251 как строка.
pub fn oneByte(c: u8) []const u8 {
    return if (c < 0x80) @as(*const [1]u8, @ptrCast(&ascii[c])) else @as(*const [1]u8, @ptrCast(&high[c - 0x80]));
}

const ascii: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = i;
    break :blk t;
};
const high: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = 0x80 + i;
    break :blk t;
};

/// Текст с пробелами, сжатыми до одного, и абзацами через пустую строку.
pub const Text = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},
    space: bool = false,
    /// Сколько знаков не перевелось («?» вместо символа).
    unknown: usize = 0,
    budget: *Budget,

    pub fn byte(t: *Text, c: u8) Error!void {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0xA0 or c == 0x0C) {
            t.space = t.buf.items.len > 0 and t.buf.items[t.buf.items.len - 1] != '\n';
            return;
        }
        if (c < 0x20) return;
        try t.budget.take(2);
        if (t.space) try t.buf.append(t.a, ' ');
        t.space = false;
        try t.buf.append(t.a, c);
    }

    pub fn bytes(t: *Text, s: []const u8) Error!void {
        for (s) |c| try t.byte(c);
    }

    pub fn unicode(t: *Text, u: u21) Error!void {
        const s = fromUnicode(u);
        if (s.len == 1 and s[0] == '?' and u != '?') t.unknown += 1;
        try t.bytes(s);
    }

    /// UTF-8 (или уже windows-1251, если `utf8 = false`) с сущностями XML и HTML.
    pub fn markup(t: *Text, raw: []const u8, utf8: bool) Error!void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '&') {
                const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse raw.len;
                if (end < raw.len and end - i <= 10) {
                    if (entity(raw[i + 1 .. end])) |u| {
                        if (u == 0xA0) try t.byte(' ') else try t.unicode(u);
                        i = end + 1;
                        continue;
                    }
                }
                try t.byte('&');
                i += 1;
            } else if (c < 0x80 or !utf8) {
                try t.byte(c);
                i += 1;
            } else {
                const u, const l = cp.utf8Next(raw, i);
                try t.unicode(u);
                i += @max(l, 1);
            }
        }
    }

    /// Разрыв строки внутри абзаца (стихи, <br>).
    pub fn line(t: *Text) Error!void {
        const s = t.buf.items;
        t.space = false;
        if (s.len == 0 or s[s.len - 1] == '\n') return;
        try t.buf.append(t.a, '\n');
    }

    /// Конец абзаца.
    pub fn para(t: *Text) Error!void {
        t.space = false;
        while (t.buf.items.len > 0 and t.buf.items[t.buf.items.len - 1] == '\n') t.buf.items.len -= 1;
        if (t.buf.items.len == 0) return;
        try t.buf.appendSlice(t.a, "\n\n");
    }

    pub fn len(t: *const Text) usize {
        return std.mem.trimRight(u8, t.buf.items, "\n ").len;
    }

    pub fn take(t: *Text) []const u8 {
        const s = std.mem.trimRight(u8, t.buf.items, "\n ");
        t.buf = .{};
        t.space = false;
        return s;
    }
};

pub fn entity(name: []const u8) ?u21 {
    if (name.len > 1 and name[0] == '#') {
        const u = (if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) else std.fmt.parseInt(u21, name[1..], 10)) catch return null;
        return if (u == 0 or (u >= 0xD800 and u <= 0xDFFF)) null else u;
    }
    const table = .{
        .{ "amp", '&' },     .{ "lt", '<' },      .{ "gt", '>' },      .{ "quot", '"' },    .{ "apos", '\'' },   .{ "nbsp", 0xA0 },
        .{ "mdash", 0x2014 }, .{ "ndash", 0x2013 }, .{ "laquo", 0xAB },  .{ "raquo", 0xBB },  .{ "hellip", 0x2026 }, .{ "shy", 0xAD },
        .{ "ldquo", 0x201C }, .{ "rdquo", 0x201D }, .{ "bdquo", 0x201E }, .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 }, .{ "sbquo", 0x201A },
        .{ "copy", 0xA9 },   .{ "reg", 0xAE },    .{ "trade", 0x2122 }, .{ "sect", 0xA7 },   .{ "deg", 0xB0 },    .{ "plusmn", 0xB1 },
        .{ "bull", 0x2022 }, .{ "middot", 0xB7 }, .{ "para", 0xB6 },   .{ "euro", 0x20AC }, .{ "times", 0xD7 },  .{ "minus", 0x2212 },
        .{ "thinsp", 0x2009 }, .{ "ensp", 0x2002 }, .{ "emsp", 0x2003 }, .{ "dagger", 0x2020 }, .{ "prime", 0x2032 }, .{ "numero", 0x2116 },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

/// Значение атрибута `name="…"` в теге.
pub fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, name)) |i| {
        from = i + 1;
        if (i > 0 and !isSpace(tag[i - 1]) and tag[i - 1] != ':') continue;
        var q = i + name.len;
        while (q < tag.len and isSpace(tag[q])) q += 1;
        if (q >= tag.len or tag[q] != '=') continue;
        q += 1;
        while (q < tag.len and isSpace(tag[q])) q += 1;
        if (q >= tag.len or (tag[q] != '"' and tag[q] != '\'')) continue;
        const end = std.mem.indexOfScalarPos(u8, tag, q + 1, tag[q]) orelse return null;
        return tag[q + 1 .. end];
    }
    return null;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0;
}

/// Имя тега без пространства имён: `<dc:title …>` → `title`.
pub fn tagName(tag: []const u8) []const u8 {
    var s = tag;
    if (s.len > 0 and s[0] == '/') s = s[1..];
    var end: usize = 0;
    while (end < s.len and !isSpace(s[end]) and s[end] != '/' and s[end] != '>') end += 1;
    s = s[0..end];
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| s = s[c + 1 ..];
    return s;
}

test "zip, сущности, абзацы" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget = Budget{ .left = 1 << 20 };
    var t = Text{ .a = a, .budget = &budget };
    try t.markup("  Раз &mdash;\n два&nbsp;три &#1071; &bogus; ", true);
    try t.para();
    try t.markup("строка", true);
    try t.line();
    try t.markup("ещё", true);
    try t.para();
    try std.testing.expectEqualStrings(cp.text("Раз — два три Я &bogus;\n\nстрока\nещё"), t.take());
    try std.testing.expectEqualStrings("href", tagName("xlink:href x"));
    try std.testing.expectEqualStrings("a b", attr("item id = 'a b' href=\"x\"", "id").?);
    try std.testing.expectError(error.Damaged, Zip.open(a, "PK\x05\x06"));
    try std.testing.expectError(error.Damaged, Zip.open(a, "x" ** 100));
    var small = Budget{ .left = 10 };
    try std.testing.expectError(error.TooBig, small.take(11));
}
