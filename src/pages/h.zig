//! Общие кусочки страниц: таблица-список и «калитка» перед формой.

const std = @import("std");
const cp = @import("../cp1251.zig");
const auth = @import("../auth.zig");
const Ctx = @import("../app.zig").Ctx;
const snapshot = @import("../snapshot.zig");
const imgstore = @import("../imgstore.zig");
const image = @import("../img/image.zig");

/// Доля a/b в процентах с двумя знаками: «37.50».
fn pct(buf: *[16]u8, a: u64, b: u64) []const u8 {
    const v = (a * 10000 + b / 2) / @max(b, 1);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ v / 100, v % 100 }) catch "0";
}

/// Картинка книги в месте `box_w`×`box_h`: место сохраняет пропорции при
/// любой ширине колонки (нижний отступ в процентах), картинка вписана в него
/// целиком и стоит по центру по обеим осям — при любом соотношении сторон.
/// Положение и размер посчитаны здесь в процентах места: работает без CSS3,
/// в старых браузерах тоже. Подпись — под местом.
pub fn figure(c: *Ctx, im: *const snapshot.Image, box_w: u32, box_h: u32) void {
    const w = &c.w;
    var nb: [24]u8 = undefined;
    const name = imgstore.fileName(&nb, im.hash, @enumFromInt(im.kind));
    // картинка больше места (место меньше 800×600) — вписывается и здесь
    const fw, const fh = image.fit(im.w, im.h, box_w, box_h);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    var b4: [16]u8 = undefined;
    var b5: [16]u8 = undefined;
    const cap = c.db.s.str(im.caption);
    w.f("<div class=\"fig\" style=\"max-width:{d}px;margin:1em auto\"><div style=\"position:relative;height:0;padding-bottom:{s}%;overflow:hidden\">", .{ box_w, pct(&b1, box_h, box_w) });
    w.f("<img src=\"/img/b/{s}\" width=\"{d}\" height=\"{d}\" alt=\"{h}\" style=\"position:absolute;left:{s}%;top:{s}%;width:{s}%;height:{s}%\"></div>", .{
        name, fw, fh, cap, pct(&b2, box_w - fw, 2 * @as(u64, box_w)), pct(&b3, box_h - fh, 2 * @as(u64, box_h)), pct(&b4, fw, box_w), pct(&b5, fh, box_h),
    });
    if (cap.len > 0) w.f("<div class=\"cap\" align=\"center\"><small>{h}</small></div>", .{cap});
    w.raw("</div>");
}

/// Таблица `class="list"`; без строк превращается в «Пусто.».
pub const Table = struct {
    c: *Ctx,
    start: usize,
    rows: usize = 0,

    pub fn begin(c: *Ctx, comptime heads: []const []const u8) Table {
        const t = Table{ .c = c, .start = c.w.n };
        c.w.raw("<table class=\"list\"><tr>");
        inline for (heads) |h| {
            c.w.raw("<th>");
            c.w.s(h);
            c.w.raw("</th>");
        }
        c.w.raw("</tr>");
        return t;
    }

    pub fn row(t: *Table) void {
        t.rows += 1;
        t.c.w.raw("<tr>");
    }

    pub fn end(t: *Table) void {
        if (t.rows == 0) {
            t.c.w.n = t.start;
            t.c.w.s("<p class=\"muted\">Пусто.</p>");
        } else t.c.w.raw("</table>");
    }
};

/// Показывать ли форму: функция включена, посетитель вошёл и имеет право.
/// Иначе пишет подсказку и возвращает false.
pub fn gate(c: *Ctx, right: u8, f: auth.Feature) bool {
    if (!c.featureOpen(f)) {
        c.w.s("<p class=\"muted\">Функция отключена администратором.</p>");
        return false;
    }
    if (c.me == null) {
        c.w.f("<p class=\"box\">Чтобы участвовать, <a href=\"{U}/signin?back={q}{E}\">войдите</a> или <a href=\"{U}/signup{E}\">зарегистрируйтесь</a>.</p>", .{c.here()});
        return false;
    }
    if (!c.can(right, f)) {
        c.w.f("<p class=\"box\">У вас нет права: <b>{s}</b>.</p>", .{auth.rightLabel(right)});
        return false;
    }
    return true;
}

/// Метки через запятую → `<span class="tag">`.
pub fn tags(c: *Ctx, csv: []const u8) void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |t| {
        const s = std.mem.trim(u8, t, " ");
        if (s.len > 0) c.w.f("<span class=\"tag\">{h}</span>", .{s});
    }
}

/// Абзацы текста: пустая строка делит, одиночный перевод строки — `<br>`.
/// Абзацы текста, как их нумеруют цитаты: через пустую строку, пустые пропускаются.
pub fn paraList(a: std.mem.Allocator, text: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitSequence(u8, text, "\n\n");
    while (it.next()) |p| {
        const s = std.mem.trim(u8, p, "\n");
        if (s.len == 0) continue;
        out.append(s) catch break;
    }
    return out.items;
}

/// Абзацы с якорями p0, p1, … — для выделения цитат (marks.js ищет #booktext и id="pN").
pub fn parasIds(c: *Ctx, text: []const u8, comptime tag: []const u8, comptime class: []const u8) void {
    c.w.raw("<div id=\"booktext\" class=\"" ++ class ++ "\">");
    // у стихов (class verse — pre-wrap) переводы строк остаются сами, у прозы — <br>
    const fmt = if (comptime std.mem.eql(u8, class, "verse")) "{h}" else "{b}";
    for (paraList(c.a, text), 0..) |p, i| c.w.f("<" ++ tag ++ " id=\"p{d}\"><a name=\"p{d}\"></a>" ++ fmt ++ "</" ++ tag ++ ">\n", .{ i, i, p });
    c.w.raw("</div>");
}

pub fn paras(c: *Ctx, text: []const u8) void {
    var it = std.mem.splitSequence(u8, text, "\n\n");
    var first = true;
    while (it.next()) |p| {
        const s = std.mem.trim(u8, p, "\n");
        if (s.len == 0) continue;
        if (!first) c.w.byte('\n');
        first = false;
        c.w.f("<p>{b}</p>", .{s});
    }
}
