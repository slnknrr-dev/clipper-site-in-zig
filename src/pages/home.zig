//! Главная страница и тексты сайта по видимым разделам (DIGITALLIBRARY_RU_RND.md).
//!
//! Полный сайт (видны все пять разделов) — главная макета, без изменений.
//! Любое другое сочетание собирает главную из блоков видимых разделов: первым
//! идёт главный раздел (у сайта из одного-двух разделов он и задаёт характер —
//! песенник, читальня, форум, цитатник, мастерская), за ним остальные. Каждая
//! тема подаёт блоки по-своему, как её оригинал:
//!
//!   flibusta  строки «Название (читать) скачать: (fb2) - (epub) - Автор»
//!   samlib    плотный список под цветными полосами-заголовками
//!   proza     анонсы: название, автор и начало текста
//!   nepomn    таблицы с первой строкой текста, сортировка по заголовку
//!
//! Тексты (описание сайта, слоганы шапок) тоже собираются из видимых разделов:
//! выключенный раздел нигде не называется.

const std = @import("std");
const cp = @import("../cp1251.zig");
const http = @import("../http.zig");
const dbm = @import("../db.zig");
const app = @import("../app.zig");
const theme = @import("../theme.zig");
const W = @import("../out.zig").W;
const Ctx = app.Ctx;
const Sec = app.sections.Sec;
const B = app.sections.bit;
const Set = app.sections.Set;
const h = @import("h.zig");

const T = cp.text;
const all: Set = 0b11111;

/// Разделы, видимые посетителю, — набор битов p, b, d, f, q.
pub fn listed(c: *const Ctx) Set {
    var set: Set = 0;
    inline for (.{ Sec.p, Sec.b, Sec.d, Sec.f, Sec.q }) |s| {
        if (c.secListed(s)) set |= B(s);
    }
    return set;
}

pub const Archetype = enum { full, songbook, reading, reading_quotes, forum, quotes, workshop, mixed };

pub fn archetype(set: Set) Archetype {
    if (set == all) return .full;
    if (set == B(.p)) return .songbook;
    if (set == B(.b)) return .reading;
    if (set == B(.b) | B(.q)) return .reading_quotes;
    if (set == B(.f)) return .forum;
    if (set == B(.q)) return .quotes;
    if (set == B(.d) | B(.f) or set == B(.d) | B(.f) | B(.p) or set == B(.d)) return .workshop;
    return .mixed;
}

/// Главный раздел: от него характер сайта и порядок блоков.
pub fn primary(set: Set) Sec {
    return switch (archetype(set)) {
        .songbook => .p,
        .reading, .reading_quotes => .b,
        .forum => .f,
        .quotes => .q,
        .workshop => .d,
        else => for ([_]Sec{ .b, .p, .q, .d, .f }) |s| {
            if (set & B(s) != 0) break s;
        } else .b,
    };
}

fn has(set: Set, s: Sec) bool {
    return set & B(s) != 0;
}

// ───────────── тексты ─────────────

/// Чем сайт назван в шапке («библиотека», «песенник»…).
pub fn kindNoun(set: Set) []const u8 {
    if (has(set, .b)) return T("библиотека");
    return switch (primary(set)) {
        .p => T("песенник"),
        .q => T("цитатник"),
        .f => T("форум"),
        .d => T("мастерская"),
        .b => T("библиотека"),
        .v => T("фонотека"),
    };
}

/// Описание сайта: перечень видимых разделов. Для полного сайта — строка макета.
pub fn describe(w: *W, set: Set) void {
    if (set == all) return w.s("Цифровая библиотека: цитаты, статьи, черновики, книги и серии, поэзия, песни с нотами, форумы и анонимные доски.");
    const n = kindNoun(set);
    w.byte(cp.upper(n[0]));
    w.raw(n[1..]);
    w.raw(": ");
    var first = true;
    const parts = [_]struct { Sec, []const u8 }{
        .{ .q, T("цитаты") },                  .{ .d, T("статьи и черновики") },
        .{ .b, T("книги и серии") },           .{ .p, T("стихи и песни с нотами") },
        .{ .f, T("форумы и анонимные доски") },
    };
    for (parts) |x| if (has(set, x[0])) {
        if (!first) w.raw(", ");
        first = false;
        w.raw(x[1]);
    };
    w.byte('.');
}

/// Перечень в родительном падеже: «цитат, книг и стихов». Для полного сайта — как у proza в макете.
pub fn listGenitive(w: *W, set: Set) void {
    if (set == all) return w.s("цитат, книг, стихов и черновиков");
    const parts = [_]struct { Sec, []const u8 }{
        .{ .q, T("цитат") }, .{ .b, T("книг") }, .{ .p, T("стихов") }, .{ .d, T("черновиков и статей") }, .{ .f, T("разговоров") },
    };
    var total: usize = 0;
    for (parts) |x| total += @intFromBool(has(set, x[0]));
    var i: usize = 0;
    for (parts) |x| if (has(set, x[0])) {
        if (i > 0) w.raw(if (i + 1 == total) T(" и ") else ", ");
        w.raw(x[1]);
        i += 1;
    };
}

/// Слоган шапки flibusta.
pub fn slogan(w: *W, set: Set) void {
    if (has(set, .b) and has(set, .q)) return w.s("Книжное братство цитат");
    if (has(set, .b)) return w.s("Книжное братство");
    w.raw(switch (primary(set)) {
        .p => T("Братство стихов и песен"),
        .q => T("Братство цитат"),
        .f => T("Братство собеседников"),
        .d => T("Братство пишущих"),
        .b => T("Книжное братство"),
        .v => T("Братство чтецов"),
    });
}

/// Заголовок samlib «Журнал "…"».
pub fn samlibTitle(w: *W, set: Set) void {
    if (set == all or (has(set, .q) and has(set, .b))) return w.s("Журнал \"Цитатник\"");
    w.raw(switch (primary(set)) {
        .p => T("Журнал \"Песенник\""),
        .q => T("Журнал \"Цитатник\""),
        .f => T("Журнал \"Форум\""),
        .d => T("Журнал \"Мастерская\""),
        .b => T("Журнал \"Читальня\""),
        .v => T("Журнал \"Фонотека\""),
    });
}

// ───────────── главная ─────────────

/// Главная для неполного сайта. false — сайт полный, главную рисует main.home.
pub fn render(c: *Ctx) bool {
    const set = listed(c);
    if (set == all) return false;
    const w = &c.w;
    const base = c.th.base;
    const main = primary(set);
    w.f("\n<h2>{h}</h2>\n<p>", .{c.app.name});
    describe(w, set);
    w.raw("</p>\n");
    if (base == .nepomn) w.raw(sort_js);
    block(c, base, main, true);
    for ([_]Sec{ .b, .p, .q, .d, .f }) |s| if (s != main and has(set, s)) block(c, base, s, false);
    c.page(.{ .title = T("Главная") });
    return true;
}

fn block(c: *Ctx, base: theme.Base, s: Sec, main: bool) void {
    switch (s) {
        .b => books(c, base, main),
        .p => pieces(c, base, main),
        .q => quotes(c, base, main),
        .d => drafts(c, base, main),
        .f => forums(c, base, main),
        .v => {},
    }
}

/// Заголовок блока в манере темы.
fn head(c: *Ctx, base: theme.Base, title: []const u8) void {
    const w = &c.w;
    switch (base) {
        .samlib => w.f("<table width=\"100%\" class=\"c3\" cellpadding=\"3\"><tr><td><b>{s}:</b></td></tr></table>\n", .{title}),
        .proza => w.f("<h3>{s}</h3>\n", .{title}),
        else => w.f("<h3>{s}</h3>\n", .{title}),
    }
}

/// Первая строка текста (стих, аннотация, черновик).
fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trimLeft(u8, text, " \r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    const line = std.mem.trim(u8, t[0..end], " \r");
    return line[0..@min(line.len, 120)];
}

// ───────────── книги ─────────────

fn books(c: *Ctx, base: theme.Base, main: bool) void {
    const w = &c.w;
    const s = c.db.s;
    const max: usize = if (main) 15 else 5;
    head(c, base, if (main) T("Новинки") else T("Новые книги"));
    const dl = c.featureOn(.downloads);
    switch (base) {
        .nepomn => w.s("<table class=\"list sortable\" width=\"100%\"><tr><th>Название</th><th>Автор</th><th>Год</th><th>Первая строка</th></tr>"),
        .samlib => w.raw("<ul>"),
        else => {},
    }
    var k: usize = s.books.len;
    var n: usize = 0;
    while (k > 0 and n < max) : (n += 1) {
        k -= 1;
        const b = s.bookAt(k);
        const title = s.str(b.title);
        switch (base) {
            .flibusta => {
                w.f("<div><a href=\"{U}/b/{d}{E}\">{h}</a> (<a href=\"{U}/q/{d}{E}\">читать</a>)", .{ b.id, title, b.id });
                if (dl) w.f(" скачать: (<a href=\"/b/{d}/fb2\">fb2</a>) - (<a href=\"/b/{d}/epub\">epub</a>)", .{ b.id, b.id });
                w.raw(" - ");
                c.bookAuthor(b.id, b.author);
                w.raw("</div>\n");
            },
            .samlib => {
                w.f("<li><a href=\"{U}/b/{d}{E}\"><b>{h}</b></a> <small>", .{ b.id, title });
                c.bookAuthor(b.id, b.author);
                w.f(", {h}</small>", .{s.str(b.year)});
                if (main) w.f("<br><small>{h}</small>", .{firstLine(s.str(b.annotation))});
                w.raw("</li>\n");
            },
            .proza => {
                w.f("<p><a href=\"{U}/b/{d}{E}\"><b>{h}</b></a><br><span class=\"muted\">", .{ b.id, title });
                c.bookAuthor(b.id, b.author);
                w.f("</span><br>{h}</p>\n", .{firstLine(s.str(b.annotation))});
            },
            .nepomn => {
                w.f("<tr><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ b.id, title });
                c.bookAuthor(b.id, b.author);
                w.f("</td><td>{h}</td><td><i>{h}</i></td></tr>\n", .{ s.str(b.year), firstLine(s.str(b.annotation)) });
            },
        }
    }
    switch (base) {
        .nepomn => w.raw("</table>"),
        .samlib => w.raw("</ul>"),
        else => {},
    }
    if (main and s.series.len > 0) {
        head(c, base, T("Серии"));
        for (s.series) |x| {
            w.f("<div><a href=\"{U}/b/{d}{E}\">{h}</a> — ", .{ x.id, s.str(x.title) });
            c.aLink(x.author);
            w.f(" ({d})</div>\n", .{x.books.len});
        }
    }
    w.f("<p><a href=\"{U}/b{E}\">Все книги &raquo;</a></p>\n", .{});
}

// ───────────── стихи и песни ─────────────

fn pieces(c: *Ctx, base: theme.Base, main: bool) void {
    const w = &c.w;
    const s = c.db.s;
    if (main) {
        // алфавит по первой строке — как оглавление сборника
        var seen = [_]bool{false} ** 256;
        for (0..s.pieces.len) |i| {
            const fl = firstLine(s.str(s.pieceAt(i).text));
            if (fl.len > 0) seen[cp.upper(fl[0])] = true;
        }
        head(c, base, T("По первой строке"));
        w.raw("<p class=\"alpha\">");
        for (seen, 0..) |on, ch| if (on) w.f("[<a href=\"#l{d}\">{s}</a>] ", .{ ch, &[1]u8{@intCast(ch)} });
        w.raw("</p>\n");
        if (base == .nepomn) w.s("<table class=\"list sortable\" width=\"100%\"><tr><th>Первая строка</th><th>Название</th><th>Жанр</th><th>Автор</th></tr>");
        for (seen, 0..) |on, ch| {
            if (!on) continue;
            if (base != .nepomn) w.f("<p><a name=\"l{d}\"></a><b>{s}</b></p>\n", .{ ch, &[1]u8{@intCast(ch)} });
            for (0..s.pieces.len) |i| {
                const p = s.pieceAt(i);
                const fl = firstLine(s.str(p.text));
                if (fl.len == 0 or cp.upper(fl[0]) != ch) continue;
                pieceLine(c, base, p, fl, @intCast(ch));
            }
        }
        if (base == .nepomn) w.raw("</table>");
    } else {
        head(c, base, T("Стихи и песни"));
        var k: usize = s.pieces.len;
        var n: usize = 0;
        if (base == .nepomn) w.s("<table class=\"list sortable\" width=\"100%\"><tr><th>Первая строка</th><th>Название</th><th>Жанр</th><th>Автор</th></tr>");
        while (k > 0 and n < 5) : (n += 1) {
            k -= 1;
            const p = s.pieceAt(k);
            pieceLine(c, base, p, firstLine(s.str(p.text)), 0);
        }
        if (base == .nepomn) w.raw("</table>");
    }
    w.f("<p><a href=\"{U}/p{E}\">Все стихи и песни &raquo;</a></p>\n", .{});
}

fn pieceLine(c: *Ctx, base: theme.Base, p: *const @import("../snapshot.zig").Piece, fl: []const u8, letter: u8) void {
    const w = &c.w;
    const s = c.db.s;
    const song = p.id < 0;
    switch (base) {
        .nepomn => {
            if (letter != 0) w.f("<tr><td><a name=\"l{d}\"></a><i>{h}</i></td>", .{ letter, fl }) else w.f("<tr><td><i>{h}</i></td>", .{fl});
            w.f("<td><a href=\"{U}/p/{d}{E}\">{h}</a></td><td>{h}{s}</td><td>", .{ p.id, s.str(p.title), s.str(p.genre), if (song) T(" (аккорды)") else "" });
            c.aLink(p.author);
            w.raw("</td></tr>\n");
        },
        .proza => {
            w.f("<p><a href=\"{U}/p/{d}{E}\"><b>{h}</b></a> <span class=\"muted\">", .{ p.id, s.str(p.title) });
            c.aLink(p.author);
            w.f(" · {h}</span><br><i>{h}</i></p>\n", .{ s.str(p.genre), fl });
        },
        .samlib => {
            w.f("<li><a href=\"{U}/p/{d}{E}\"><b>{h}</b></a> <small>", .{ p.id, s.str(p.title) });
            c.aLink(p.author);
            w.f(" · {h}</small><br><small><i>{h}</i></small></li>\n", .{ s.str(p.genre), fl });
        },
        .flibusta => {
            w.f("<div><i>{h}</i> — <a href=\"{U}/p/{d}{E}\">{h}</a> - ", .{ fl, p.id, s.str(p.title) });
            c.aLink(p.author);
            w.f(" <span class=\"muted\">({h})</span></div>\n", .{s.str(p.genre)});
        },
    }
}

// ───────────── цитаты ─────────────

fn quotes(c: *Ctx, base: theme.Base, main: bool) void {
    const w = &c.w;
    const s = c.db.s;
    const qs = c.db.quotes();
    head(c, base, T("Цитата дня"));
    if (qs.len == 0) {
        w.s("<p class=\"muted\">Цитат пока нет: их делают из книг — выделите фрагмент на странице чтения.</p>\n");
    } else {
        const q = qs[http.civil(c.app.now).day % qs.len];
        quoteItem(c, q, main);
    }
    if (qs.len > 1) {
        head(c, base, T("Свежие цитаты"));
        var k = qs.len;
        var n: usize = 0;
        while (k > 0 and n < @as(usize, if (main) 10 else 3)) : (n += 1) {
            k -= 1;
            quoteItem(c, qs[k], false);
        }
    }
    if (main) {
        head(c, base, T("Люди"));
        if (base == .nepomn) w.s("<table class=\"list sortable\"><tr><th>Кто</th><th>Цитат</th></tr>");
        for (s.persons) |p| {
            var n: usize = 0;
            for (qs) |q| n += @intFromBool(q.person == p.id);
            if (base == .nepomn) {
                w.f("<tr><td><a href=\"{U}/c/{d}{E}\">{h}</a></td><td>{d}</td></tr>", .{ p.id, s.str(p.name), n });
            } else w.f("<div><a href=\"{U}/c/{d}{E}\">{h}</a> <span class=\"muted\">({d})</span></div>\n", .{ p.id, s.str(p.name), n });
        }
        if (base == .nepomn) w.raw("</table>");
        const chars = c.db.characters();
        if (chars.len > 0) {
            head(c, base, T("Персонажи"));
            for (chars) |p| {
                w.f("<div><a href=\"{U}/c/{d}{E}\">{h}</a> — ", .{ p.id, p.name });
                c.aLink(p.author);
                w.raw("</div>\n");
            }
        }
    }
    w.f("<p><a href=\"{U}/c{E}\">Все цитаты &raquo;</a></p>\n", .{});
}

fn quoteItem(c: *Ctx, q: dbm.Quote, big: bool) void {
    const w = &c.w;
    if (big) w.f("<blockquote><font size=\"+1\">{h}</font><br><span class=\"muted\">— ", .{q.text}) else w.f("<blockquote>{h}<br><span class=\"muted\">— ", .{q.text});
    c.aLink(q.person);
    switch (q.src) {
        'p' => if (c.secReadable(.p)) w.f(" · <a href=\"{U}/p/{d}#p{d}{E}\">к месту в стихе</a>", .{ q.book, q.para }),
        'd' => if (c.secReadable(.d)) w.f(" · <a href=\"{U}/d/{d}#p{d}{E}\">к месту в статье</a>", .{ q.book, q.para }),
        else => if (c.secReadable(.b)) w.f(" · <a href=\"{U}/b/{d}/{d}#p{d}{E}\">к месту в книге</a>", .{ q.book, q.ch, q.para }),
    }
    w.raw("</span></blockquote>\n");
}

// ───────────── черновики и статьи ─────────────

fn drafts(c: *Ctx, base: theme.Base, main: bool) void {
    const w = &c.w;
    inline for (.{ false, true }) |neg| {
        head(c, base, if (neg) T("Статьи") else T("Свежие черновики"));
        const list = c.db.drafts(neg);
        if (base == .nepomn) w.s("<table class=\"list sortable\" width=\"100%\"><tr><th>Название</th><th>Автор</th><th>Дата</th><th>Первая строка</th></tr>");
        var k = list.len;
        var n: usize = 0;
        while (k > 0 and n < @as(usize, if (main) 8 else 3)) : (n += 1) {
            k -= 1;
            const d = list[k];
            switch (base) {
                .nepomn => {
                    w.f("<tr><td><a href=\"{U}/d/{d}{E}\">{h}</a></td><td>", .{ d.id, d.title });
                    c.aLink(d.author);
                    w.f("</td><td>{h}</td><td><i>{h}</i></td></tr>", .{ d.created, firstLine(d.text) });
                },
                else => {
                    w.f("<div><a href=\"{U}/d/{d}{E}\"><b>{h}</b></a> — ", .{ d.id, d.title });
                    c.aLink(d.author);
                    w.f(" <span class=\"muted\">{h}</span>", .{d.created});
                    if (base == .proza or (base == .samlib and main)) w.f("<br><i>{h}</i>", .{firstLine(d.text)});
                    w.raw("</div>\n");
                },
            }
        }
        if (base == .nepomn) w.raw("</table>");
    }
    w.f("<p><a href=\"{U}/d{E}\">Все черновики и статьи &raquo;</a></p>\n", .{});
}

// ───────────── форумы ─────────────

fn forums(c: *Ctx, base: theme.Base, main: bool) void {
    const w = &c.w;
    const posts = c.db.allPosts();
    head(c, base, T("Форумы"));
    w.raw(if (base == .nepomn) "<table class=\"list sortable\" width=\"100%\">" else "<table class=\"list\" width=\"100%\">");
    w.s("<tr><th>Форум</th><th>Тем</th><th>Сообщений</th><th>Последнее</th></tr>");
    for (c.db.forums()) |f| {
        var n: usize = 0;
        var last: ?dbm.Post = null;
        for (posts) |p| if (p.forum == f.id) {
            n += 1;
            if (last == null or p.id > last.?.id) last = p;
        };
        w.f("<tr><td><a href=\"{U}/f/{d}{E}\"><b>{h}</b></a>", .{ f.id, f.title });
        if (main) w.f("<br><span class=\"muted\">{h}</span>", .{f.about});
        w.f("</td><td>{d}</td><td>{d}</td><td>", .{ c.db.topics(f.id).len, n });
        if (last) |p| {
            w.f("{h} ", .{p.date});
            c.aLink(p.author);
        }
        w.raw("</td></tr>\n");
    }
    w.raw("</table>\n");
    if (main and c.featureOn(.boards)) {
        head(c, base, T("Анонимные доски"));
        for (c.db.boards()) |b| w.f("<div><a href=\"{U}/f/{s}{E}\">/{s}/</a> — {h}</div>\n", .{ b.id, b.id, b.title });
    }
    w.f("<p><a href=\"{U}/f{E}\">Все форумы &raquo;</a></p>\n", .{});
}

// ───────────── сортировка таблиц nepomn ─────────────

/// Как на nepomn.ru: щелчок по заголовку колонки сортирует таблицу. DOM 1 и
/// ES3 — работает в IE5+ и Netscape 6+; без скриптов таблица просто не сортируется.
const sort_js =
    \\<script type="text/javascript"><!--
    \\function srt(th){var tb=th.parentNode.parentNode,i,j,c=0,r=[],x=th;while(x.previousSibling){x=x.previousSibling;if(x.nodeType==1)c++;}
    \\for(i=1;i<tb.rows.length;i++)r[r.length]=tb.rows[i];
    \\function k(row){var t=row.cells[c];return t?(t.innerText||t.textContent||"").toLowerCase():"";}
    \\var d=th.getAttribute("dir")=="1"?-1:1;th.setAttribute("dir",d==1?"1":"0");
    \\r.sort(function(a,b){var p=k(a),q=k(b);var m=parseFloat(p),n=parseFloat(q);if(!isNaN(m)&&!isNaN(n))return (m-n)*d;return p<q?-d:p>q?d:0;});
    \\for(j=0;j<r.length;j++)tb.appendChild(r[j]);}
    \\window.onload=function(){var t=document.getElementsByTagName("table"),i,j;for(i=0;i<t.length;i++)if(t[i].className.indexOf("sortable")>=0){var h=t[i].rows[0].cells;for(j=0;j<h.length;j++){h[j].style.cursor="pointer";h[j].onclick=function(){srt(this);};}}};
    \\//--></script>
    \\
;

test "архетип и главный раздел по видимым разделам" {
    try std.testing.expectEqual(Archetype.full, archetype(all));
    try std.testing.expectEqual(Archetype.songbook, archetype(B(.p)));
    try std.testing.expectEqual(Archetype.reading_quotes, archetype(B(.b) | B(.q)));
    try std.testing.expectEqual(Archetype.mixed, archetype(all & ~B(.d)));
    try std.testing.expectEqual(Sec.d, primary(B(.d) | B(.f)));
    try std.testing.expectEqual(Sec.b, primary(all & ~B(.f)));
    var buf: [256]u8 = undefined;
    var w = W.init(&buf);
    describe(&w, B(.p) | B(.f));
    // фраза собирается из кусков, поэтому ожидание — своё для каждого языка сборки
    try std.testing.expectEqualStrings(if (@import("config").lang == .en) "Songbook: poems and songs with notes, forums and anonymous boards." else T("Песенник: стихи и песни с нотами, форумы и анонимные доски."), w.out());
    w.n = 0;
    listGenitive(&w, B(.q) | B(.b) | B(.p));
    try std.testing.expectEqualStrings(if (@import("config").lang == .en) "quotes, books and poems" else T("цитат, книг и стихов"), w.out());
}
