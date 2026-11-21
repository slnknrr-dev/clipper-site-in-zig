//! Писатель страницы: байты в заранее выделенный буфер, без выделений памяти.
//! Строки формата — UTF-8 в исходнике, в windows-1251 они превращаются при
//! компиляции. Спецификаторы `f`:
//!
//!   {s} байты как есть        {h} с экранированием HTML     {b} то же, \n → <br>
//!   {d} целое                 {q} для адреса (%XX)
//!   {U} … {E} — адрес сайта: в конец дописываются протягиваемые `m` и `t`.

const std = @import("std");
const cp = @import("cp1251.zig");
const t9n = @import("t9n.zig");

pub const W = struct {
    buf: []u8,
    n: usize = 0,
    over: bool = false,
    /// "m=true&amp;t=samlib" — уже пригодно для атрибута href; пусто, если нечего протягивать.
    tm: []const u8 = "",
    link_at: usize = 0,
    /// Где в теле стоит токен CSRF (для кэша страниц гостей).
    csrf_at: [32]u32 = undefined,
    csrf_n: u8 = 0,
    csrf_many: bool = false,

    pub fn init(buf: []u8) W {
        return .{ .buf = buf };
    }

    pub fn out(w: *const W) []const u8 {
        return w.buf[0..w.n];
    }

    pub fn raw(w: *W, bytes: []const u8) void {
        if (w.n + bytes.len > w.buf.len) {
            w.over = true;
            return;
        }
        @memcpy(w.buf[w.n..][0..bytes.len], bytes);
        w.n += bytes.len;
    }

    pub fn byte(w: *W, c: u8) void {
        if (w.n == w.buf.len) {
            w.over = true;
            return;
        }
        w.buf[w.n] = c;
        w.n += 1;
    }

    /// Строка исходника, перекодированная при компиляции.
    pub inline fn s(w: *W, comptime utf8: []const u8) void {
        w.raw(comptime cp.lit(utf8));
    }

    pub fn esc(w: *W, bytes: []const u8) void {
        for (bytes) |c| switch (c) {
            '&' => w.raw("&amp;"),
            '<' => w.raw("&lt;"),
            '>' => w.raw("&gt;"),
            '"' => w.raw("&quot;"),
            '\'' => w.raw("&#39;"),
            else => w.byte(c),
        };
    }

    pub fn escBr(w: *W, bytes: []const u8) void {
        for (bytes) |c| switch (c) {
            '&' => w.raw("&amp;"),
            '<' => w.raw("&lt;"),
            '>' => w.raw("&gt;"),
            '"' => w.raw("&quot;"),
            '\'' => w.raw("&#39;"),
            '\n' => w.raw("<br>\n"),
            else => w.byte(c),
        };
    }

    /// Текст книги: как `escBr`, но адреса http:// и https:// становятся ссылками.
    /// Адрес кончается на пробеле, переводе строки или знаке, которого в адресах
    /// не бывает; знаки препинания в его конце остаются текстом.
    pub fn escBrLinks(w: *W, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len) {
            const rest = bytes[at..];
            const i = std.mem.indexOf(u8, rest, "http") orelse break;
            const tail = rest[i..];
            if (!std.mem.startsWith(u8, tail, "http://") and !std.mem.startsWith(u8, tail, "https://")) {
                w.escBr(rest[0 .. i + 4]);
                at += i + 4;
                continue;
            }
            var end: usize = 0;
            while (end < tail.len and tail[end] > ' ' and tail[end] < 0x7f and std.mem.indexOfScalar(u8, "<>\"'()", tail[end]) == null) end += 1;
            while (end > 0 and std.mem.indexOfScalar(u8, ".,;:!?", tail[end - 1]) != null) end -= 1;
            w.escBr(rest[0..i]);
            w.raw("<a href=\"");
            w.esc(tail[0..end]);
            w.raw("\">");
            w.esc(tail[0..end]);
            w.raw("</a>");
            at += i + end;
        }
        w.escBr(bytes[at..]);
    }

    pub fn int(w: *W, v: i64) void {
        var b: [24]u8 = undefined;
        w.raw(std.fmt.bufPrint(&b, "{d}", .{v}) catch unreachable);
    }

    pub fn urlenc(w: *W, bytes: []const u8) void {
        const hex = "0123456789ABCDEF";
        for (bytes) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => w.byte(c),
            ' ' => w.byte('+'),
            else => {
                w.byte('%');
                w.byte(hex[c >> 4]);
                w.byte(hex[c & 15]);
            },
        };
    }

    pub fn linkBegin(w: *W) void {
        w.link_at = w.n;
    }

    /// Дописывает `m` и `t` к адресу, начатому `linkBegin` (перед `#…`, если он есть).
    pub fn linkEnd(w: *W) void {
        if (w.tm.len == 0 or w.over) return;
        const seg = w.buf[w.link_at..w.n];
        const has_q = std.mem.indexOfScalar(u8, seg, '?') != null;
        const sep: []const u8 = if (has_q) "&amp;" else "?";
        const add = sep.len + w.tm.len;
        if (w.n + add > w.buf.len) {
            w.over = true;
            return;
        }
        const hash = if (std.mem.indexOfScalar(u8, seg, '#')) |h| w.link_at + h else w.n;
        std.mem.copyBackwards(u8, w.buf[hash + add .. w.n + add], w.buf[hash..w.n]);
        @memcpy(w.buf[hash..][0..sep.len], sep);
        @memcpy(w.buf[hash + sep.len ..][0..w.tm.len], w.tm);
        w.n += add;
    }

    /// Адрес сайта с `m`/`t`, экранированный для атрибута.
    pub fn link(w: *W, path: []const u8) void {
        w.linkBegin();
        w.esc(path);
        w.linkEnd();
    }

    /// Вставляет готовый кусок вместе с его отметками токена CSRF.
    pub fn embed(w: *W, other: *const W) void {
        const base = w.n;
        w.raw(other.out());
        if (w.over) return;
        w.csrf_many = w.csrf_many or other.csrf_many;
        for (other.csrf_at[0..other.csrf_n]) |at| {
            if (w.csrf_n == w.csrf_at.len) {
                w.csrf_many = true;
                break;
            }
            w.csrf_at[w.csrf_n] = @intCast(base + at);
            w.csrf_n += 1;
        }
    }

    pub fn markCsrf(w: *W, token: []const u8) void {
        if (w.csrf_n == w.csrf_at.len) w.csrf_many = true else {
            w.csrf_at[w.csrf_n] = @intCast(w.n);
            w.csrf_n += 1;
        }
        w.raw(token);
    }

    fn arg(w: *W, comptime spec: u8, v: anytype) void {
        switch (spec) {
            's' => w.raw(v),
            'h' => w.esc(v),
            'b' => w.escBr(v),
            'q' => w.urlenc(v),
            'd' => w.int(@intCast(v)),
            else => @compileError("неизвестный спецификатор"),
        }
    }

    pub fn f(w: *W, comptime source_fmt: []const u8, args: anytype) void {
        // Переводится строка целиком: в другом языке слова вокруг подстановок стоят иначе.
        const fmt = comptime t9n.tr(source_fmt);
        comptime var i: usize = 0;
        comptime var from: usize = 0;
        comptime var ai: usize = 0;
        inline while (i < fmt.len) {
            if (comptime (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 2] == '}' and std.mem.indexOfScalar(u8, "shbqdUE", fmt[i + 1]) != null)) {
                if (from < i) w.raw(comptime cp.lit(fmt[from..i]));
                const spec = fmt[i + 1];
                if (spec == 'U') {
                    w.linkBegin();
                } else if (spec == 'E') {
                    w.linkEnd();
                } else {
                    w.arg(spec, args[ai]);
                    ai += 1;
                }
                i += 3;
                from = i;
            } else i += 1;
        }
        if (from < fmt.len) w.raw(comptime cp.lit(fmt[from..]));
        comptime if (ai != args.len) @compileError("лишние аргументы в f: " ++ fmt);
    }
};

/// Экранирование для XML/HTML без таблицы писателя.
pub fn escAlloc(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var n: usize = 0;
    for (bytes) |c| n += switch (c) {
        '&' => 5,
        '<', '>' => 4,
        '"' => 6,
        '\'' => 5,
        else => 1,
    };
    const buf = try a.alloc(u8, n);
    var w = W.init(buf);
    w.esc(bytes);
    return buf;
}

test "формат и адреса" {
    var buf: [256]u8 = undefined;
    var w = W.init(&buf);
    w.tm = "t=samlib";
    w.f("<a href=\"{U}/b/{d}#p{d}{E}\">{h}</a>", .{ 2, 0, "a<b" });
    try std.testing.expectEqualStrings("<a href=\"/b/2?t=samlib#p0\">a&lt;b</a>", w.out());
    w.n = 0;
    w.f("{U}/s?q={q}{E}", .{"a b"});
    try std.testing.expectEqualStrings("/s?q=a+b&amp;t=samlib", w.out());
    w.n = 0;
    w.escBrLinks("см. https://example.org/a?b=1&c=2. И http без адреса");
    try std.testing.expectEqualStrings("см. <a href=\"https://example.org/a?b=1&amp;c=2\">https://example.org/a?b=1&amp;c=2</a>. И http без адреса", w.out());
}
