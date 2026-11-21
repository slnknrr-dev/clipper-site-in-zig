//! /e/… — маленькие страницы для чужого `<iframe>`. Ссылки открываются в `_top`.

const std = @import("std");
const cp = @import("../cp1251.zig");
const dbm = @import("../db.zig");
const badge = @import("../badge.zig");
const app_mod = @import("../app.zig");
const W = @import("../out.zig").W;
const Ctx = app_mod.Ctx;
const marks = @import("marks.zig");
const theme = @import("../theme.zig");

const T = cp.text;

fn open(w: *W, title: []const u8) void {
    w.f("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">\n<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\"><title>{h}</title><base target=\"_top\">\n<style type=\"text/css\">", .{title});
    var b1: [7]u8 = undefined;
    var b2: [7]u8 = undefined;
    var b3: [7]u8 = undefined;
    var b4: [7]u8 = undefined;
    w.f("body{margin:0;padding:6px;background:{s};color:#393939;font:11px Verdana,Arial,sans-serif;border:1px solid {s}}\na{color:{s}}h1{font-size:13px;margin:0 0 3px}.m{color:#888;font-size:10px}.t{font:13px Georgia,serif;line-height:1.4;white-space:pre-wrap}\n.f{margin-top:4px;border-top:1px solid {s};padding-top:2px;font-size:9px;color:#888}table{font-size:11px}</style></head>\n<body>", .{ theme.tint(&b1, .flibusta, "#fdfeff"), theme.tint(&b2, .flibusta, "#96b4d5"), theme.tint(&b3, .flibusta, "#24375b"), theme.tint(&b4, .flibusta, "#d1dbec") });
}

fn foot(c: *Ctx, w: *W, comptime fmt: []const u8, args: anytype) void {
    w.raw("<div class=\"f\"><a href=\"");
    w.f(fmt, args);
    w.f("\"><b>{h}</b></a> · цифровая библиотека</div>", .{c.app.name});
}

fn close(c: *Ctx) void {
    c.out.raw("</body></html>");
    c.send(app_mod.html_type, c.out.out());
}

fn off(c: *Ctx, comptime msg: []const u8) void {
    open(&c.out, "off");
    c.out.s(msg);
    close(c);
}

/// Текст с `<br>` вместо переводов строк (как в макете: без `\n` после него).
fn nl(w: *W, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (line.len > 0 and line[0] == 1) continue; // метка картинки
        if (!first) w.raw("<br>");
        first = false;
        w.esc(line);
    }
}

pub fn serve(c: *Ctx, kind: []const u8, arg: []const u8) void {
    const w = &c.out;
    const s = c.db.s;
    const eq = std.mem.eql;
    const known = eq(u8, kind, "b") or eq(u8, kind, "p") or eq(u8, kind, "c") or eq(u8, kind, "d") or eq(u8, kind, "u") or eq(u8, kind, "f") or eq(u8, kind, "stat") or eq(u8, kind, "banner");
    if (!known) return c.notFound();
    if (kind.len == 1) {
        const path = [_]u8{ '/', kind[0] };
        if (!c.pathListed(&path)) return c.notFound();
    }
    if (!c.featureOn(.embed)) return off(c, "Встраивание отключено.");
    const id: i32 = std.fmt.parseInt(i32, arg, 10) catch (if (arg.len == 0) 0 else return c.notFound());

    if (eq(u8, kind, "b")) {
        const b = s.book(id) orelse return c.notFound();
        const title = s.str(b.title);
        const st = c.app.stat(c.db, id);
        if (!st.embed) {
            open(w, "off");
            w.f("Автор запретил встраивание. <a href=\"/b/{d}\">Открыть книгу</a>", .{id});
            return close(c);
        }
        const ch = c.qInt("ch");
        if (ch >= 1 and ch <= b.n_pages) {
            const n: u32 = @intCast(ch);
            c.app.countRead(id, false);
            const ch_title = s.str(s.bookPages(b)[n - 1].title);
            const text = c.app.pageText(c.a, b, n - 1) catch return c.notFound();
            open(w, title);
            w.f("<h1>{h} — {h}</h1><div class=\"t\">", .{ title, ch_title });
            nl(w, text);
            w.raw("</div>\n<div class=\"m\">");
            if (n > 1) w.f("<a href=\"/e/b/{d}?ch={d}\" target=\"_self\">&laquo;</a> ", .{ id, n - 1 });
            w.f("глава {d} из {d}", .{ n, b.n_pages });
            if (n < b.n_pages) w.f(" <a href=\"/e/b/{d}?ch={d}\" target=\"_self\">&raquo;</a>", .{ id, n + 1 });
            w.raw("</div>");
            foot(c, w, "/b/{d}/{d}", .{ id, n });
            return close(c);
        }
        open(w, title);
        w.f("<table cellpadding=\"0\" cellspacing=\"0\"><tr><td valign=\"top\"><img src=\"/logo64.png{s}\" width=\"48\" height=\"48\" alt=\"\" style=\"margin-right:6px;border:1px solid #96b4d5\"></td><td valign=\"top\">\n<h1><a href=\"/b/{d}\">{h}</a></h1><div class=\"m\">{h}", .{ theme.asset_q, id, title, c.db.name(b.author) });
        if (b.year.len > 0) w.f(", {h}", .{s.str(b.year)});
        w.f(" · глав: {d} · прочтений: {d}</div>\n<div>{h}</div><div><a href=\"/e/b/{d}?ch=1\" target=\"_self\">Читать здесь</a> · <a href=\"/b/{d}/1\">на сайте</a></div></td></tr></table>", .{ b.n_pages, st.reads, s.str(b.annotation), id, id });
        foot(c, w, "/b/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "p")) {
        const p = c.db.piece(id) orelse return c.notFound();
        open(w, p.title);
        w.f("<h1>{h}</h1><div class=\"m\">{h} · {h}</div><div class=\"t\">", .{ p.title, c.db.name(p.author), p.genre });
        nl(w, p.text);
        w.raw("</div>");
        if (p.chords.len > 0) w.f("<pre style=\"font-size:10px\">{h}</pre>", .{p.chords});
        foot(c, w, "/p/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "c")) {
        const p = c.db.person(id) orelse return c.notFound();
        const op = c.q("op");
        const ed = c.q("ed");
        const sz: usize = @intCast(std.math.clamp(c.qInt("sz"), 0, 30));
        var text: []const u8 = "";
        for (c.db.quotes()) |q| {
            if (q.person != id) continue;
            if (op.len > 0 and cp.indexOfFold(q.text, op) == null) continue;
            text = q.text;
            break;
        }
        if (text.len > 0) {
            // конец, которого нет в цитате, не мешает показать её с начала
            const with_ed = marks.cut(c.a, text, op, ed, sz);
            text = with_ed orelse (marks.cut(c.a, text, op, "", sz) orelse text);
        }
        open(w, p.name);
        w.f("<div class=\"t\">&laquo;{h}&raquo;</div><div class=\"m\" align=\"right\">— <a href=\"/c/{d}\">{h}</a></div>", .{ if (text.len > 0) text else T("…"), id, p.name });
        foot(c, w, "/c/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "d")) {
        const d = c.db.draft(id) orelse return c.notFound();
        open(w, d.title);
        w.f("<h1>{h}</h1><div class=\"m\">{h} · {h} · {s}</div><div class=\"t\">", .{ d.title, c.db.name(d.author), d.created, if (id < 0) T("статья") else T("черновик") });
        nl(w, d.text[0..@min(d.text.len, 600)]);
        if (d.text.len > 600) w.s("…");
        w.raw("</div>");
        foot(c, w, "/d/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "u")) {
        const u = c.db.user(id) orelse return c.notFound();
        open(w, u.nick);
        w.f("<h1><a href=\"/u/{d}\">{h}</a></h1><div class=\"m\">{s} с {h}</div>\n<img src=\"/x/u/books.png?id={d}\" alt=\"\"> <img src=\"/x/u/posts.png?id={d}&amp;color=blue\" alt=\"\">", .{ id, u.nick, if (id < 0) T("автор") else T("участник"), u.joined, id, id });
        foot(c, w, "/u/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "f")) {
        if (!c.featureOn(.forum)) return off(c, "Форум отключён.");
        const f = c.db.forum(id) orelse return c.notFound();
        open(w, f.title);
        w.f("<h1>Форум «{h}»</h1>", .{f.title});
        const topics = c.db.topics(id);
        if (topics.len == 0) w.s("<span class=m>тем нет</span>");
        var k = topics.len;
        while (k > topics.len -| 5) {
            k -= 1;
            if (k + 1 < topics.len) w.raw("<br>");
            w.f("&raquo; <a href=\"/f/{d}?topic={d}\">{h}</a> <span class=\"m\">({d})</span>", .{ id, topics[k].id, topics[k].title, c.db.posts(topics[k].id).len });
        }
        foot(c, w, "/f/{d}", .{id});
        return close(c);
    }
    if (eq(u8, kind, "stat")) {
        open(w, "stat");
        w.f("<h1>Статистика {h}</h1>", .{c.app.name});
        w.s("<table width=\"100%\" cellspacing=\"0\">");
        const rows = [_]struct { []const u8, i64 }{
            .{ cp.lit("Книг"), @intCast(s.books.len) },
            .{ cp.lit("Стихов и песен"), @intCast(s.pieces.len) },
            .{ cp.lit("Цитат"), @intCast(c.db.l.count(c.a, "Q")) },
            .{ cp.lit("Черновиков"), @intCast(c.db.l.count(c.a, "D")) },
            .{ cp.lit("Участников"), @intCast(c.db.l.count(c.a, "A") + 1) },
            .{ cp.lit("Сейчас на сайте"), @intCast(c.db.l.count(c.a, "S")) },
            .{ cp.lit("Прочтений"), badge.totalReads(c) },
            .{ cp.lit("Просмотров"), @intCast(c.app.views) },
        };
        var b_odd: [7]u8 = undefined;
        var b_even: [7]u8 = undefined;
        for (rows, 0..) |r, i| w.f("<tr bgcolor=\"{s}\"><td>{s}</td><td align=\"right\"><b>{d}</b></td></tr>", .{ theme.tint(if (i % 2 == 1) &b_odd else &b_even, .flibusta, if (i % 2 == 1) "#fbfcfe" else "#eef3f9"), r[0], r[1] });
        w.raw("</table>");
        foot(c, w, "/", .{});
        return close(c);
    }
    // banner
    const big = eq(u8, c.q("size"), "468");
    const nq: i64 = @intCast(c.db.l.count(c.a, "Q"));
    w.raw("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\"><html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\"><base target=\"_top\"></head>\n<body style=\"margin:0\"><a href=\"/\" style=\"display:block;");
    w.raw(if (big) "width:468px;height:60px" else "width:88px;height:31px");
    var bc: [7]u8 = undefined;
    var bb: [7]u8 = undefined;
    var bg: [64]u8 = undefined;
    w.f(";overflow:hidden;text-decoration:none;background:{s} url(/g/{d}/{s}.bmp) repeat-x;border:1px solid {s};font:bold {d}px Verdana,sans-serif;color:#fff;text-align:center\">\n<table width=\"100%\" height=\"100%\" cellspacing=\"0\" cellpadding=\"0\"><tr><td align=\"center\" style=\"color:#fff;font:bold {d}px Verdana\">", .{ theme.tint(&bc, .flibusta, "#5294c1"), @as(i64, if (big) 60 else 31), theme.tintGrad(&bg, .flibusta, "abcbef-83a5c9-24375b"), theme.tint(&bb, .flibusta, "#24375b"), @as(i64, if (big) 18 else 10), @as(i64, if (big) 18 else 10) });
    if (big) {
        w.f("<img src=\"/logo64.png{s}\" width=\"48\" height=\"48\" align=\"absmiddle\" alt=\"\"> CLIPPER — книг: {d}, цитат: {d}", .{ theme.asset_q, s.books.len, nq });
    } else w.f("CLIPPER<br><span style=\"font-size:8px\">книг: {d}</span>", .{s.books.len});
    w.raw("</td></tr></table></a></body></html>");
    c.send(app_mod.html_type, w.out());
}

const Item = struct { title: []const u8, url: []const u8, w: u16, h: u16, note: []const u8 };

/// /e — демонстрация всех встраиваемых кусков: живой iframe и код для копирования.
pub fn demo(c: *Ctx) void {
    const w = &c.w;
    const items = [_]Item{
        .{ .title = cp.lit("Книга (карточка)"), .url = if (@import("../library.zig").has_book0) "/e/b/0" else "/e/b/1", .w = 320, .h = 150, .note = cp.lit("любая книга: /e/b/{id}") },
        .{ .title = cp.lit("Книга (глава)"), .url = "/e/b/2?ch=3", .w = 320, .h = 220, .note = cp.lit("?ch=N — читать главу прямо во фрейме") },
        .{ .title = cp.lit("Стихотворение"), .url = "/e/p/2", .w = 260, .h = 170, .note = "/e/p/{id}" },
        .{ .title = cp.lit("Песня с аккордами"), .url = "/e/p/-1", .w = 260, .h = 260, .note = "/e/p/{-id}" },
        .{ .title = cp.lit("Цитата с фильтром"), .url = cp.text("/e/c/-3?op=Зри&sz=2"), .w = 300, .h = 110, .note = "/e/c/{person}?op=&amp;ed=&amp;sz=" },
        .{ .title = cp.lit("Статья"), .url = "/e/d/-1", .w = 300, .h = 200, .note = "/e/d/{id}" },
        .{ .title = cp.lit("Участник"), .url = "/e/u/-101", .w = 240, .h = 100, .note = "/e/u/{id}" },
        .{ .title = cp.lit("Форум"), .url = "/e/f/1", .w = 240, .h = 110, .note = "/e/f/{id}" },
        .{ .title = cp.lit("Статистика"), .url = "/e/stat", .w = 220, .h = 210, .note = "/e/stat" },
        .{ .title = cp.lit("Плашка 88×31"), .url = "/e/banner", .w = 90, .h = 33, .note = "/e/banner" },
        .{ .title = cp.lit("Баннер 468×60"), .url = "/e/banner?size=468", .w = 470, .h = 62, .note = "/e/banner?size=468" },
    };
    const badges = [_][2][]const u8{
        .{ "/x/b/reads.svg?id=0", cp.lit("прочтения книги") },
        .{ "/x/b/comments.png?id=2", cp.lit("комментарии (PNG)") },
        .{ "/x/u/books.svg?id=-101&color=blue", cp.lit("книги автора") },
        .{ "/x/site/users.svg?color=navy", cp.lit("участников") },
        .{ "/x/site/online.png", cp.lit("сейчас на сайте") },
        .{ "/x/s/p.svg?label=poems&color=maroon", cp.lit("раздел стихов") },
    };
    w.s("<h2>Встраивание: демонстрация</h2>");
    if (!c.featureOn(.embed)) w.s("<div class=\"box\"><b>Встраивание сейчас отключено администратором — фреймы покажут заглушку.</b></div>");
    w.s("\n<p>Любой кусок библиотеки можно вставить на свою страницу через <code>&lt;iframe&gt;</code>. Ссылки внутри открываются в основном окне.</p>\n<table class=\"list\">");
    for (items) |it| {
        if (!c.pathListed(it.url)) continue;
        w.f("<tr><td width=\"45%\" valign=\"top\"><b>{s}</b><br><span class=\"muted\">{s}</span><br>\n<textarea rows=\"2\" cols=\"40\" readonly style=\"width:100%;font-size:10px\">&lt;iframe src=&quot;", .{ it.title, it.note });
        c.origin(w);
        w.f("{h}&quot; width=&quot;{d}&quot; height=&quot;{d}&quot; frameborder=&quot;0&quot; scrolling=&quot;no&quot;&gt;&lt;/iframe&gt;</textarea></td>\n<td valign=\"top\"><iframe src=\"{h}\" width=\"{d}\" height=\"{d}\" frameborder=\"0\" scrolling=\"no\" title=\"{s}\"></iframe></td></tr>", .{ it.url, it.w, it.h, it.url, it.w, it.h, it.title });
    }
    w.s("</table>\n<h3>Бейджи</h3><p class=\"muted\">Формат <code>/x/{вид}/{метод}[.svg|.png]?id=&amp;label=&amp;color=</code>; без расширения — JSON.</p>\n<table class=\"list\">");
    for (badges) |b| {
        const url = b[0];
        if (!c.pathListed(url)) continue;
        // адрес JSON — тот же без расширения
        const dot = std.mem.indexOf(u8, url, ".svg") orelse std.mem.indexOf(u8, url, ".png") orelse url.len;
        w.f("<tr><td><img src=\"{h}\" alt=\"{s}\"></td><td>{s}</td><td><code>{h}</code> · <a href=\"{h}{h}\">JSON</a></td></tr>", .{ url, b[1], b[1], url, url[0..dot], url[@min(url.len, dot + 4)..] });
    }
    w.raw("</table>");
    c.page(.{ .title = T("Встраивание"), .crumbs = &.{.{ .text = T("Встраивание") }} });
}
