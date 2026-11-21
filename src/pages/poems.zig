//! Стихи и песни от имени автора (BACKLOG_RU.md §20): /p/new — выложить, /p/N/edit —
//! править, /p/N/delete — удалить; на странице участника — привязка к людям
//! каталога («этот участник и есть Тютчев»).
//!
//! Выкладывает любой участник с правом «черновики, стихи, статьи» (write) — от
//! имени любого автора: человека каталога (новый заводится по имени) или себя.
//! Править и удалять могут: кто выложил; участник, привязанный к автору (всё его);
//! сотрудник (staff) и /u/0 — всё. Привязывают сотрудник и /u/0.

const std = @import("std");
const cp = @import("../cp1251.zig");
const dbm = @import("../db.zig");
const chordpro = @import("../chordpro.zig");
const source = @import("source.zig");
const voice = @import("voice.zig");
const Ctx = @import("../app.zig").Ctx;

const T = cp.text;

/// Жанры (windows-1251, как хранятся).
const genres = [_][]const u8{ T("стихи"), T("верлибр"), T("авторская песня"), T("песня с аккордами") };
const song_genre = 3;

/// Может ли участник править и удалять работу автора `author`, выложенную `uploader`.
pub fn canEdit(c: *const Ctx, author: i32, uploader: i32) bool {
    const me = c.me orelse return false;
    if (!c.secWritable(.p)) return false;
    if (c.isModerator()) return true;
    if (uploader != 0 and me.user == uploader) return true;
    if (me.user == author) return true;
    for (c.db.authorsOf(me.user)) |p| if (p == author) return true;
    return false;
}

fn mayPublish(c: *const Ctx) bool {
    return c.can(dbm.rights.write, .poems) and c.featureOpen(.poems) and c.secWritable(.p);
}

/// Форма стиха: новая (p == null) или правка.
fn form(c: *Ctx, action: []const u8, p: ?dbm.Piece) void {
    const w = &c.w;
    const s = c.db.s;
    const me = c.me.?.user;
    w.f("<form action=\"{s}\" method=\"post\" class=\"box\">", .{action});
    c.post();
    if (p == null) voice.voiceField(c);
    w.f("\n<table><tr><td>Название</td><td><input name=\"title\" size=\"40\" value=\"{h}\"></td></tr>\n<tr><td valign=\"top\">Автор</td><td><select name=\"author\">", .{if (p) |x| x.title else ""});
    const cur = if (p) |x| x.author else voice.voiceAuthor(c);
    w.f("<option value=\"{d}\"{s}>я сам ({h})</option>", .{ me, if (cur == me) " selected" else "", c.db.name(me) });
    for (s.persons) |x| {
        if (x.id <= 0) continue;
        w.f("<option value=\"{d}\"{s}>{h}", .{ x.id, if (cur == x.id) " selected" else "", s.str(x.name) });
        if (x.years.len > 0) w.f(" ({h})", .{s.str(x.years)});
        w.raw("</option>");
    }
    if (cur != 0 and cur != me and s.person(cur) == null) w.f("<option value=\"{d}\" selected>{h}</option>", .{ cur, c.db.name(cur) });
    w.s("</select><br>или новый: <input name=\"new_author\" size=\"24\"> годы жизни <input name=\"years\" size=\"10\"><br><span class=\"muted\">Имя, которого ещё нет на сайте, заводится как новый автор.</span></td></tr>\n<tr><td>Жанр</td><td><select name=\"genre\">");
    for (genres, 0..) |g, k| {
        const sel = if (p) |x| (if (x.id < 0) k == song_genre else std.mem.eql(u8, x.genre, g)) else k == 0;
        w.f("<option{s}>", .{if (sel) " selected" else ""});
        w.esc(g);
        w.raw("</option>");
    }
    w.f("</select> год <input name=\"year\" size=\"6\" value=\"{h}\"></td></tr>\n", .{if (p) |x| x.year else ""});
    source.row(c, if (p) |x| c.db.source('p', x.id) else "");
    w.f("<tr><td valign=\"top\">Текст</td><td><textarea name=\"text\" rows=\"14\" cols=\"60\" style=\"width:100%\">{h}</textarea><br>", .{if (p) |x| x.text else ""});
    w.s("<span class=\"muted\">Для песни с аккордами — ChordPro: аккорды в квадратных скобках прямо в словах, <code>[Am]Ночь, бен[Dm]зин и ветер</code>; припев — между строками <code>{soc}</code> и <code>{eoc}</code>, пояснение — <code>{c: текст}</code>.</span></td></tr>\n");
    w.f("<tr><td valign=\"top\">Ноты</td><td><textarea name=\"notes\" rows=\"4\" cols=\"60\" style=\"width:100%\">{h}</textarea><br>", .{if (p) |x| x.notes else ""});
    w.s("<span class=\"muted\">Необязательно: мелодия в ABC-нотации (для песен).</span></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"Сохранить\"></td></tr></table></form>");
}

pub fn newPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    if (c.me == null) return c.redirect("/signin?back=/p/new", .{});
    if (!mayPublish(c)) return c.denied(T("Нужно право «черновики, стихи, статьи»."));
    w.s("<h2>Выложить стих или песню</h2>");
    c.msgBox(msg);
    form(c, "/p/new", null);
    c.page(.{ .title = T("Выложить стих"), .sec = "/p", .crumbs = &.{ .{ .text = T("Стихи"), .href = "/p" }, .{ .text = T("Выложить") } } });
}

/// Поля формы → стих; null — ошибка (сообщение уже показано).
fn fromForm(c: *Ctx, id: i32, old: ?dbm.Piece) ?dbm.Piece {
    const me = c.me.?.user;
    const title = std.mem.trim(u8, c.form.get("title"), " \r\n\t");
    const text = std.mem.trimRight(u8, c.form.get("text"), " \r\n\t");
    if (title.len == 0 or text.len == 0) return null;
    var author: i32 = std.fmt.parseInt(i32, c.form.get("author"), 10) catch me;
    const new_name = std.mem.trim(u8, c.form.get("new_author"), " \r\n\t");
    if (new_name.len > 0) {
        const years = std.mem.trim(u8, c.form.get("years"), " ");
        author = c.db.personByName(new_name[0..@min(new_name.len, 120)], years[0..@min(years.len, 30)], "");
        if (author == 0) return null;
    } else if (author != me and c.db.s.person(author) == null and !(old != null and old.?.author == author)) {
        return null; // автор не из списка
    }
    const genre_s = c.form.get("genre");
    var gk: usize = 0;
    for (genres, 0..) |g, k| if (std.mem.eql(u8, genre_s, g)) {
        gk = k;
    };
    const year = std.mem.trim(u8, c.form.get("year"), " ");
    const notes = std.mem.trimRight(u8, c.form.get("notes"), " \r\n\t");
    return .{
        .id = id,
        .title = title[0..@min(title.len, 200)],
        .author = author,
        .genre = genres[gk],
        .year = year[0..@min(year.len, 10)],
        .text = text,
        .notes = notes,
        .uploader = if (old) |o| o.uploader else me,
        .chordpro = gk == song_genre,
        .seq = if (old) |o| o.seq else 0,
    };
}

pub fn newPost(c: *Ctx) void {
    if (c.me == null) return c.redirect("/signin?back=/p/new", .{});
    if (!mayPublish(c)) return c.denied(T("Нужно право «черновики, стихи, статьи»."));
    const song = std.mem.eql(u8, c.form.get("genre"), genres[song_genre]);
    var id: i32 = undefined;
    while (true) {
        id = if (song) c.db.nextId("pieceNeg", -3, -1) else c.db.nextId("piece", 1, 1);
        if (c.db.s.piece(id) == null and c.db.pieceRec(id) == null) break;
    }
    const p = fromForm(c, id, null) orelse {
        c.status = 400;
        return newPage(c, T("Нужны название, текст и автор из списка (или имя нового автора)."));
    };
    c.db.putPiece(p);
    source.save(c, 'p', id);
    voice.attachNew(c, 'p', id);
    c.app.rebuild_wanted = true;
    c.redirect("/p/{d}", .{id});
}

/// Стих для правки: из хранилища (заведённые на сайте) или из снимка.
fn current(c: *Ctx, id: i32) ?dbm.Piece {
    return c.db.pieceRec(id) orelse c.db.piece(id);
}

pub fn editPage(c: *Ctx, id: i32, msg: []const u8) void {
    const w = &c.w;
    const p = current(c, id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin?back=/p/{d}/edit", .{id});
    if (!canEdit(c, p.author, p.uploader)) return c.denied(T("Править может тот, кто выложил, сам автор, сотрудник или /u/0."));
    w.f("<h2>Правка: {h}</h2>", .{p.title});
    c.msgBox(msg);
    form(c, std.fmt.allocPrint(c.a, "/p/{d}/edit", .{id}) catch "/p", p);
    w.f("\n<form action=\"/p/{d}/delete\" method=\"post\" class=\"box\">", .{id});
    c.post();
    w.s("<label><input type=\"checkbox\" name=\"sure\" value=\"1\"> да, удалить насовсем</label> <input type=\"submit\" value=\"Удалить\"></form>");
    c.page(.{ .title = T("Правка"), .sec = "/p", .crumbs = &.{ .{ .text = T("Стихи"), .href = "/p" }, .{ .text = p.title, .href = std.fmt.allocPrint(c.a, "/p/{d}", .{id}) catch "/p" }, .{ .text = T("Правка") } } });
}

pub fn editPost(c: *Ctx, id: i32) void {
    const old = current(c, id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEdit(c, old.author, old.uploader)) return c.denied(T("Править может тот, кто выложил, сам автор, сотрудник или /u/0."));
    var p = fromForm(c, id, old) orelse {
        c.status = 400;
        return editPage(c, id, T("Нужны название, текст и автор из списка (или имя нового автора)."));
    };
    // номер не меняется: песня остаётся песней, стих — стихом
    if (id > 0) {
        p.chordpro = false;
        if (std.mem.eql(u8, p.genre, genres[song_genre])) p.genre = genres[2];
    } else {
        p.genre = genres[song_genre];
        // старая песня (аккорды отдельным полем) остаётся такой, пока в тексте не появятся аккорды ChordPro
        const old_style = !old.chordpro and old.chords.len > 0;
        p.chordpro = !old_style or chordpro.looksLike(p.text);
        p.chords = if (p.chordpro) "" else old.chords;
    }
    c.db.putPiece(p);
    source.save(c, 'p', id);
    c.app.rebuild_wanted = true;
    c.redirect("/p/{d}", .{id});
}

pub fn deletePost(c: *Ctx, id: i32) void {
    const p = current(c, id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEdit(c, p.author, p.uploader)) return c.denied(T("Удалить может тот, кто выложил, сам автор, сотрудник или /u/0."));
    if (!c.form.on("sure")) {
        c.status = 400;
        return editPage(c, id, T("Отметьте «да, удалить насовсем»."));
    }
    c.db.delPiece(id);
    c.db.setSource('p', id, "");
    c.app.rebuild_wanted = true;
    c.redirect("/p", .{});
}

// ───────────── привязка участника к авторам ─────────────

/// На странице участника: кто он в каталоге (всем) и форма привязки (сотрудник и /u/0).
pub fn userAuthors(c: *Ctx, uid: i32) void {
    const w = &c.w;
    const s = c.db.s;
    const bound = c.db.authorsOf(uid);
    if (bound.len > 0) {
        w.s("<p>Автор на сайте: ");
        for (bound, 0..) |p, k| {
            if (k > 0) w.raw(", ");
            c.aLink(p);
        }
        w.raw("</p>\n");
    }
    if (!c.isModerator() or uid == 0) return;
    w.f("<form action=\"/u/{d}/authors\" method=\"post\" class=\"box\">", .{uid});
    c.post();
    w.s("<b>Привязка к авторам</b> <span class=\"muted\">(участник сможет править и удалять всё, что выложено от их имени)</span><br>\n");
    for (bound) |p| {
        w.f("<label><input type=\"checkbox\" name=\"keep\" value=\"{d}\" checked> {h}</label><br>\n", .{ p, c.db.name(p) });
    }
    w.s("Добавить: <select name=\"add\"><option value=\"\">—</option>");
    for (s.persons) |x| {
        if (x.id <= 0) continue;
        var dup = false;
        for (bound) |p| dup = dup or p == x.id;
        if (dup) continue;
        w.f("<option value=\"{d}\">{h}</option>", .{ x.id, s.str(x.name) });
    }
    w.s("</select> <input type=\"submit\" value=\"Сохранить\"></form>\n");
}

pub fn authorsPost(c: *Ctx, uid: i32) void {
    if (c.me == null) return c.redirect("/signin", .{});
    if (!c.isModerator()) return c.denied(T("Привязывать участников к авторам могут сотрудник и /u/0."));
    if (uid == 0 or c.db.user(uid) == null) return c.notFound();
    var ids = std.ArrayList(i32).init(c.a);
    for (c.form.fields) |f| {
        if (!std.mem.eql(u8, f.name, "keep")) continue;
        const id = std.fmt.parseInt(i32, f.value, 10) catch continue;
        if (id > 0 and c.db.s.person(id) != null) ids.append(id) catch {};
    }
    if (std.fmt.parseInt(i32, c.form.get("add"), 10)) |id| {
        var dup = false;
        for (ids.items) |x| dup = dup or x == id;
        if (id > 0 and !dup and c.db.s.person(id) != null) ids.append(id) catch {};
    } else |_| {}
    c.db.setAuthorsOf(uid, ids.items);
    c.redirect("/u/{d}", .{uid});
}

/// На странице человека каталога: какие участники — это он.
pub fn authorUsers(c: *Ctx, pid: i32) void {
    const w = &c.w;
    const users = c.db.usersOfAuthor(pid);
    if (users.len == 0) return;
    w.s("<p>Это участник сайта: ");
    for (users, 0..) |u, k| {
        if (k > 0) w.raw(", ");
        w.f("<a href=\"{U}/u/{d}{E}\">{h}</a>", .{ u, c.db.name(u) });
    }
    w.raw("</p>\n");
}
