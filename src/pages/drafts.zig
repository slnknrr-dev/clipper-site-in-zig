//! Черновики и статьи (/d): черновик можно перенести в стихи (/p) или
//! объединить с другими в книгу (/b) — после этого он только для чтения.

const std = @import("std");
const cp = @import("../cp1251.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const Ctx = @import("../app.zig").Ctx;
const h = @import("h.zig");
const books = @import("books.zig");
const route = @import("../route.zig");
const library = @import("../library.zig");

const T = cp.text;

fn rows(c: *Ctx, negative: bool) void {
    const w = &c.w;
    var t = h.Table.begin(c, &.{ "", "№", "Название", "Автор", "Дата", "Метки" });
    for (c.db.drafts(negative)) |d| {
        t.row();
        w.raw("<td>");
        if (d.id > 0 and c.secWritable(.b)) w.f("<input type=\"checkbox\" name=\"id\" value=\"{d}\"{s}>", .{ d.id, if (d.moved.len > 0) " disabled" else "" });
        w.raw("</td><td>");
        c.sign(d.id);
        w.f("</td><td><a href=\"{U}/d/{d}{E}\">{h}</a>", .{ d.id, d.title });
        if (d.moved.len > 0) {
            if (c.pathListed(d.moved)) w.f(" <span class=\"muted\">→ {h} (только чтение)</span>", .{d.moved}) else w.s(" <span class=\"muted\">(только чтение)</span>");
        }
        w.raw("</td><td>");
        c.aLink(d.author);
        w.f("</td><td>{h}</td><td>", .{d.created});
        h.tags(c, d.tags);
        w.raw("</td></tr>");
    }
    t.end();
}

pub fn index(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    c.msgBox(msg);
    const to_book = c.secWritable(.b);
    w.s("\n<h2>Черновики и фрагменты</h2>\n");
    if (to_book) {
        w.s("<form action=\"/d/merge\" method=\"post\">");
        c.post();
    }
    w.byte('\n');
    rows(c, false);
    if (to_book) w.s("\n<div class=\"box\">Отмеченные: название книги <input name=\"title\" size=\"24\" value=\"Сборник\"> <input type=\"submit\" value=\"Объединить и опубликовать как книгу\"></div>\n</form>");
    w.s("\n<h2>Статьи</h2>");
    rows(c, true);
    w.s("\n<h2>Новый черновик</h2>\n");
    if (h.gate(c, dbm.rights.write, .drafts)) {
        w.raw("<form action=\"/d\" method=\"post\" class=\"box\">");
        c.post();
        w.s("\nТип: <label><input type=\"radio\" name=\"kind\" value=\"draft\" checked> черновик/фрагмент</label> <label><input type=\"radio\" name=\"kind\" value=\"article\"> статья</label><br>\nНазвание: <input name=\"title\" size=\"30\"><br>\n<textarea name=\"text\" rows=\"6\" cols=\"60\" style=\"width:100%\"></textarea><br>\nМетки (через запятую): <input name=\"tags\" size=\"30\"> <input type=\"submit\" value=\"Сохранить\">\n</form>");
    }
    c.page(.{ .title = T("Черновики"), .sec = "/d", .crumbs = &.{.{ .text = T("Черновики") }} });
}

pub fn draft(c: *Ctx, id: i32) void {
    const w = &c.w;
    const d = c.db.draft(id) orelse return c.notFound();
    const ro = d.moved.len > 0;
    w.f("<h2>{h} ", .{d.title});
    if (id < 0) w.s("<span class=\"muted\">(статья)</span>");
    w.raw("</h2>\n<div class=\"muted\">");
    c.aLink(d.author);
    w.f(" · {h} · ", .{d.created});
    h.tags(c, d.tags);
    w.f(" · <code>/d/{d}</code></div>\n", .{id});
    if (ro) {
        if (c.pathListed(d.moved)) w.f("<div class=\"box\">Перенесено в <a href=\"{U}{h}{E}\">{h}</a>. Черновик доступен только для чтения.</div>", .{ d.moved, d.moved }) else w.s("<div class=\"box\">Черновик доступен только для чтения.</div>");
    }
    if (id < 0) {
        // статья: из неё можно делать цитаты
        w.byte('\n');
        h.parasIds(c, d.text, "p", "text");
        @import("marks.zig").textMarkUi(c, std.fmt.allocPrint(c.a, "/d/{d}/mark", .{id}) catch "", d.author, @intCast(h.paraList(c.a, d.text).len));
    } else {
        w.raw("\n<div class=\"text\">");
        h.paras(c, d.text);
        w.raw("</div>");
    }
    if (id > 0 and !ro and c.can(dbm.rights.write, .drafts) and c.secWritable(.p)) {
        w.f("<form action=\"/d/{d}/piece\" method=\"post\" class=\"box\" style=\"display:inline-block\">", .{id});
        c.post();
        w.f("Перенести в стихи как жанр <select name=\"genre\"><option>стихи</option><option>верлибр</option><option>авторская песня</option></select> <input type=\"submit\" value=\"Перенести в /p\"></form>\n<p class=\"muted\">Объединить с другими черновиками в книгу — на <a href=\"{U}/d{E}\">списке черновиков</a>.</p>", .{});
    }
    if (mayDelete(c, d)) {
        w.f("\n<form action=\"/d/{d}/delete\" method=\"post\" class=\"box\">", .{id});
        c.post();
        w.s("<label><input type=\"checkbox\" name=\"sure\" value=\"1\"> да, удалить насовсем</label> <input type=\"submit\" value=\"Удалить\">");
        if (ro) w.s(" <span class=\"muted\">Опубликованное останется — пропадёт только отметка, что оно из черновика.</span>");
        w.raw("</form>");
    }
    c.page(.{ .title = d.title, .sec = "/d", .crumbs = &.{ .{ .text = T("Черновики"), .href = "/d" }, .{ .text = if (id > 0) T("Черновики") else T("Статьи"), .href = "/d" }, .{ .text = d.title } } });
}

/// Удалить черновик или статью может автор, сотрудник и /u/0.
fn mayDelete(c: *const Ctx, d: dbm.Draft) bool {
    const me = c.me orelse return false;
    return c.isModerator() or me.user == d.author;
}

/// След черновика в книге: номер из строки «drafts:» шапки books/N.txt.
fn eraseFromBook(c: *Ctx, book: i32, draft_id: i32) void {
    var dir = c.app.root.openDir(library.books_dir, .{}) catch return;
    defer dir.close();
    const name = std.fmt.allocPrint(c.a, "{d}.txt", .{book}) catch return;
    const src = dir.readFileAlloc(c.a, name, 64 << 20) catch return;
    if (!std.mem.startsWith(u8, src, "#clipper-book")) return;
    const head_end = std.mem.indexOf(u8, src, "\n\n") orelse return;
    var out = std.ArrayList(u8).init(c.a);
    var it = std.mem.splitScalar(u8, src[0..head_end], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "drafts:")) {
            var keep = std.ArrayList(u8).init(c.a);
            var ids = std.mem.splitScalar(u8, line["drafts:".len..], ',');
            while (ids.next()) |x| {
                const v = std.fmt.parseInt(i32, std.mem.trim(u8, x, " \r"), 10) catch continue;
                if (v == draft_id) continue;
                keep.writer().print("{s}{d}", .{ if (keep.items.len > 0) ", " else "", v }) catch return;
            }
            if (keep.items.len > 0) out.writer().print("drafts: {s}\n", .{keep.items}) catch return;
            continue;
        }
        out.appendSlice(line) catch return;
        out.append('\n') catch return;
    }
    out.appendSlice(src[head_end + 1 ..]) catch return;
    dir.writeFile(.{ .sub_path = name, .data = out.items }) catch return;
    c.app.rebuild_wanted = true;
}

/// Метки: через запятую, без пустых и без пробелов по краям.
fn cleanTags(c: *Ctx, raw: []const u8) []const u8 {
    var out = std.ArrayList(u8).init(c.a);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |t| {
        const s = std.mem.trim(u8, t, " \n");
        if (s.len == 0) continue;
        if (out.items.len > 0) out.append(',') catch break;
        out.appendSlice(s[0..@min(s.len, 40)]) catch break;
    }
    return out.items;
}

pub fn post(c: *Ctx, a: []const u8, b: []const u8) void {
    if (!c.can(dbm.rights.write, .drafts)) return c.denied(T("Нужно право «черновики, стихи, статьи»."));
    const me = c.me.?;
    if (c.seg.len == 1) {
        const article = std.mem.eql(u8, c.form.get("kind"), "article");
        const id = if (article) c.db.nextId("draftNeg", -1, -1) else c.db.nextId("draft", 1, 1);
        const title = c.form.get("title");
        const text = c.form.get("text");
        c.db.putDraft(.{ .id = id, .title = if (title.len > 0) title[0..@min(title.len, 200)] else T("Без названия"), .author = me.user, .created = c.today(), .moved = "", .tags = cleanTags(c, c.form.get("tags")), .text = if (text.len > 0) text else T("…"), .seq = c.db.nextId("dseq", 1, 1) });
        return c.redirect("/d/{d}", .{id});
    }
    if (std.mem.eql(u8, a, "merge") and c.seg.len == 2) {
        var picked = std.ArrayList(dbm.Draft).init(c.a);
        for (c.form.fields) |f| {
            if (!std.mem.eql(u8, f.name, "id")) continue;
            const id = std.fmt.parseInt(i32, std.mem.trim(u8, f.value, " "), 10) catch continue;
            if (id <= 0) continue;
            const d = c.db.draft(id) orelse continue;
            if (d.moved.len > 0) continue;
            var dup = false;
            for (picked.items) |x| dup = dup or x.id == id;
            if (!dup) picked.append(d) catch break;
        }
        if (picked.items.len < 1) return index(c, T("Отметьте хотя бы один свободный черновик."));
        var text = std.ArrayList(u8).init(c.a);
        var csv = std.ArrayList(u8).init(c.a);
        for (picked.items, 0..) |d, i| {
            if (i > 0) csv.append(',') catch {};
            csv.writer().print("{d}", .{d.id}) catch {};
            text.writer().print("## {s}\n", .{d.title}) catch {};
            // строка черновика, начинающаяся с «##», не должна стать главой
            var lines = std.mem.splitScalar(u8, d.text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "##")) text.append(' ') catch {};
                text.appendSlice(line) catch {};
                text.append('\n') catch {};
            }
        }
        const id = books.newBookId(c);
        const title = c.form.get("title");
        books.saveTextBook(c, id, if (title.len > 0) title[0..@min(title.len, 300)] else T("Сборник"), picked.items[0].author, T("Собрано из черновиков."), csv.items, text.items, true) catch return c.fail(500, T("Книга не сохранена."));
        const moved = std.fmt.allocPrint(c.a, "/b/{d}", .{id}) catch "/b";
        for (picked.items) |d| {
            var x = d;
            x.moved = moved;
            c.db.putDraft(x);
        }
        return c.redirect("/b/{d}", .{id});
    }
    if (std.mem.eql(u8, b, "delete") and c.seg.len == 3) {
        const id = route.intId(a, false) orelse return c.notFound();
        const d = c.db.draft(id) orelse return c.notFound();
        if (!mayDelete(c, d)) return c.denied(T("Удалить черновик может его автор, сотрудник или /u/0."));
        if (!c.form.on("sure")) {
            c.status = 400;
            return index(c, T("Отметьте «да, удалить насовсем»."));
        }
        // перенесённое остаётся, как будто его сразу выложили: стирается только след
        if (std.mem.startsWith(u8, d.moved, "/b/")) if (std.fmt.parseInt(i32, d.moved[3..], 10)) |book| eraseFromBook(c, book, id) else |_| {};
        c.db.l.del(L.key(c.a, "D", .{id}));
        return c.redirect("/d", .{});
    }
    if (std.mem.eql(u8, b, "piece") and c.seg.len == 3) {
        if (!c.secWritable(.p)) return c.denied(T("Раздел, куда переносят, недоступен."));
        if (!c.featureOpen(.poems)) return c.denied(T("Раздел стихов отключён."));
        const id = route.intId(a, true) orelse return c.notFound();
        var d = c.db.draft(id) orelse return c.notFound();
        if (d.moved.len > 0) return c.notFound();
        var pid: i32 = undefined;
        while (true) {
            pid = c.db.nextId("piece", 1, 1);
            if (c.db.s.piece(pid) == null) break;
        }
        const genre = c.form.get("genre");
        c.db.l.put(L.key(c.a, "p", .{pid}), L.rec(c.a, .{ d.title, d.author, if (genre.len > 0) genre[0..@min(genre.len, 60)] else T("стихи"), c.today()[0..4], d.text }));
        d.moved = std.fmt.allocPrint(c.a, "/p/{d}", .{pid}) catch "/p";
        c.db.putDraft(d);
        c.app.rebuild_wanted = true;
        return c.redirect("/p/{d}", .{pid});
    }
    c.notFound();
}
