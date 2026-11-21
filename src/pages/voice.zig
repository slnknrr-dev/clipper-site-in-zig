//! Раздел /v (BACKLOG_RU.md §22): аудиокниги, чтецы и исполнители.
//!
//!   /v           записи и чтецы             /v/new        загрузить запись
//!   /v/N         запись (N > 0)             /v/N.mp3      сам файл (с Range)
//!   /v/-N        чтец или исполнитель       /v/N/edit     правка и удаление
//!   /v/-N/edit   правка чтеца               /u/N/readers  привязка участника к чтецам
//!
//! Запись бывает двух видов:
//!   аудиокнига — к книге библиотеки (/b/N);
//!   исполнение — стиха или песни (/p/N); у исполнения могут быть свои слова
//!                и ноты (если поётся иначе).
//! Текстовая основа необязательна: запись можно выложить без книги или стиха
//! (тогда нужны название и, по желанию, автор) и связать позже в любом
//! порядке — со страницы записи (привязать к выложенной или выложить книгу,
//! стих от записи: ?voice=N) или со страницы книги, стиха (привязать запись
//! без основы или загрузить новую).
//! Чтец обязателен; участником сайта он быть не обязан, но участника можно к
//! нему привязать, как к автору (сотрудник и /u/0). Чтецом может быть сам
//! автор: чтеца связывают с автором (/c/N или участником) — «читает автор».
//! У записи может быть источник (source.zig).
//!
//! Принимается MP3 всегда, .ogg — при -Dogg (по умолчанию), .m4a — при -Dm4a.
//! Любой файл перекодируется в MP3 «как до 2003 года»: MPEG-1 Layer III,
//! CBR 128 кбит/с, ID3v1 (audio/audio.zig) — и лежит в voice/N.mp3.
//!
//! Загружает участник с правом «выкладывать книги» (upload); правят и удаляют:
//! кто загрузил, участник, привязанный к чтецу, сотрудник и /u/0.

const std = @import("std");
const cfg = @import("config");
const cp = @import("../cp1251.zig");
const http = @import("../http.zig");
const dbm = @import("../db.zig");
const chordpro = @import("../chordpro.zig");
const audio = @import("../audio/audio.zig");
const h = @import("h.zig");
const source = @import("source.zig");
const Ctx = @import("../app.zig").Ctx;

const T = cp.text;

pub const enabled = cfg.voice;
pub const dir_name = "voice";

/// Какие входные форматы принимает эта сборка.
pub fn kindAllowed(k: audio.Kind) bool {
    return switch (k) {
        .mp3 => true,
        .ogg => cfg.ogg,
        .m4a => cfg.m4a,
    };
}

fn acceptList() []const u8 {
    return if (cfg.ogg and cfg.m4a) ".mp3,.ogg,.m4a" else if (cfg.ogg) ".mp3,.ogg" else if (cfg.m4a) ".mp3,.m4a" else ".mp3";
}

fn mayUpload(c: *const Ctx) bool {
    return c.secWritable(.v) and c.can(dbm.rights.upload, null);
}

/// Есть ли у записи текстовая основа (книга или стих).
pub fn hasText(r: dbm.Recording) bool {
    return if (r.audiobook) r.book >= 0 else r.piece != 0;
}

/// Автор произведения: автор книги или стиха, а без основы — указанный при загрузке.
fn authorOf(c: *Ctx, r: dbm.Recording) i32 {
    if (hasText(r)) {
        if (r.audiobook) {
            if (c.db.s.book(r.book)) |b| return b.author;
        } else if (pieceOf(c, r.piece)) |p| return p.author;
    }
    return r.author;
}

/// Править и удалять запись: кто загрузил, привязанный к чтецу, сотрудник, /u/0.
pub fn canEdit(c: *const Ctx, r: dbm.Recording) bool {
    const me = c.me orelse return false;
    if (!c.secWritable(.v)) return false;
    if (c.isModerator()) return true;
    if (r.uploader != 0 and me.user == r.uploader) return true;
    for (c.db.readersOf(me.user)) |x| if (x == r.reader) return true;
    return false;
}

fn canEditReader(c: *const Ctx, rid: i32) bool {
    const me = c.me orelse return false;
    if (!c.secWritable(.v)) return false;
    if (c.isModerator()) return true;
    for (c.db.readersOf(me.user)) |x| if (x == rid) return true;
    return false;
}

fn duration(c: *Ctx, sec: u32) []const u8 {
    const hh = sec / 3600;
    const mm = (sec / 60) % 60;
    const ss = sec % 60;
    return if (hh > 0) std.fmt.allocPrint(c.a, "{d}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch "" else std.fmt.allocPrint(c.a, "{d}:{d:0>2}", .{ mm, ss }) catch "";
}

fn megabytes(c: *Ctx, bytes: u64) []const u8 {
    const tenth = (bytes * 10 + 512 * 1024) / (1024 * 1024);
    return std.fmt.allocPrint(c.a, "{d},{d}", .{ tenth / 10, tenth % 10 }) catch "";
}

fn readerLink(c: *Ctx, id: i32) void {
    const r = c.db.reader(id) orelse return c.w.f("#{d}", .{id});
    c.w.f("<a href=\"{U}/v/{d}{E}\">{h}</a>", .{ id, r.name });
}

/// Чтец записи; если он и есть автор — с пометкой.
fn readerOfRec(c: *Ctx, r: dbm.Recording) void {
    readerLink(c, r.reader);
    const rd = c.db.reader(r.reader) orelse return;
    const a = authorOf(c, r);
    if (rd.author != 0 and rd.author == a) c.w.s(" (автор)");
}

/// Что записано: книга или стих (ссылкой), если есть.
fn subjectLink(c: *Ctx, r: dbm.Recording) void {
    const s = c.db.s;
    if (!hasText(r)) {
        if (r.author != 0) {
            c.w.s("автор ");
            c.aLink(r.author);
            c.w.s(", ");
        }
        if (r.audiobook) c.w.s("<span class=\"muted\">книги нет</span>") else c.w.s("<span class=\"muted\">текста нет</span>");
        return;
    }
    if (r.audiobook) {
        if (s.book(r.book)) |b| {
            if (c.secListed(.b)) c.w.f("<a href=\"{U}/b/{d}{E}\">{h}</a>", .{ r.book, s.str(b.title) }) else c.w.esc(s.str(b.title));
        } else c.w.f("/b/{d}", .{r.book});
        return;
    }
    if (pieceOf(c, r.piece)) |p| {
        if (c.secListed(.p)) c.w.f("<a href=\"{U}/p/{d}{E}\">{h}</a>", .{ r.piece, p.title }) else c.w.esc(p.title);
    } else c.w.f("/p/{d}", .{r.piece});
}

fn pieceOf(c: *Ctx, id: i32) ?dbm.Piece {
    return c.db.pieceRec(id) orelse c.db.piece(id);
}

fn titleOf(c: *Ctx, r: dbm.Recording) []const u8 {
    if (r.title.len > 0) return r.title;
    if (!hasText(r)) {} else if (r.audiobook) {
        if (c.db.s.book(r.book)) |b| return c.db.s.str(b.title);
    } else if (pieceOf(c, r.piece)) |p| return p.title;
    return std.fmt.allocPrint(c.a, "/v/{d}", .{r.id}) catch "";
}

// ───────────── /v ─────────────

pub fn index(c: *Ctx) void {
    const w = &c.w;
    const all = c.db.recordings();
    w.s("<h2>Записи</h2><p>Аудиокниги и авторское исполнение: стихи читают, песни поют — авторы, барды, чтецы. Всё звучит в MP3 128 кбит/с, как до 2003 года: играет любой проигрыватель.</p>\n");
    if (mayUpload(c)) w.f("<p><a href=\"{U}/v/new{E}\">Загрузить запись</a></p>\n", .{});
    inline for (.{ true, false }) |books| {
        var t: ?h.Table = null;
        for (all) |r| {
            if (r.audiobook != books) continue;
            if (t == null) {
                w.s(if (books) "<h3>Аудиокниги</h3>" else "<h3>Исполнения стихов и песен</h3>");
                t = h.Table.begin(c, if (books) &.{ "Запись", "Книга", "Читает", "Длительность" } else &.{ "Запись", "Стих или песня", "Исполняет", "Длительность" });
            }
            t.?.row();
            w.f("<td><a href=\"{U}/v/{d}{E}\">{h}</a></td><td>", .{ r.id, titleOf(c, r) });
            subjectLink(c, r);
            w.raw("</td><td>");
            readerOfRec(c, r);
            w.f("</td><td>{s}</td>", .{duration(c, r.seconds)});
        }
        if (t) |*x| x.end();
    }
    if (all.len == 0) w.s("<p class=\"muted\">Записей пока нет.</p>\n");
    const rs = c.db.readers();
    if (rs.len > 0) {
        w.s("<h3>Чтецы и исполнители</h3><ul>");
        for (rs) |r| {
            var n: usize = 0;
            for (all) |x| n += @intFromBool(x.reader == r.id);
            w.f("<li><a href=\"{U}/v/{d}{E}\">{h}</a>", .{ r.id, r.name });
            if (r.years.len > 0) w.f(" ({h})", .{r.years});
            w.f(" <span class=\"muted\">· записей: {d}</span></li>", .{n});
        }
        w.raw("</ul>\n");
    }
    c.page(.{ .title = T("Записи"), .sec = "/v", .crumbs = &.{.{ .text = T("Записи") }} });
}

// ───────────── /v/N ─────────────

pub fn recording(c: *Ctx, id: i32) void {
    const w = &c.w;
    const r = c.db.recording(id) orelse return c.notFound();
    const title = titleOf(c, r);
    w.f("<h2>{h}</h2>\n<div class=\"muted\">{s} · ", .{ title, if (r.audiobook) T("аудиокнига") else T("исполнение") });
    subjectLink(c, r);
    if (r.audiobook) w.s(" · читает ") else w.s(" · исполняет ");
    readerOfRec(c, r);
    if (r.year.len > 0) w.f(" · {h}", .{r.year});
    w.f(" · <code>/v/{d}</code></div>\n", .{id});
    source.show(c, 'v', id);
    if (!hasText(r) and canEdit(c, r)) {
        w.s("<div class=\"box\">");
        if (r.audiobook) {
            w.f("Книги к записи пока нет: <a href=\"{U}/v/{d}/edit{E}\">привязать к выложенной</a>", .{id});
            if (c.can(dbm.rights.upload, .upload)) w.f(" или <a href=\"{U}/b/upload?voice={d}{E}\">выложить книгу</a>", .{id});
        } else {
            w.f("Текста к записи пока нет: <a href=\"{U}/v/{d}/edit{E}\">привязать к выложенному стиху или песне</a>", .{id});
            if (c.can(dbm.rights.write, .poems) and c.featureOpen(.poems) and c.secWritable(.p)) w.f(" или <a href=\"{U}/p/new?voice={d}{E}\">выложить текст</a>", .{id});
        }
        w.raw(".</div>\n");
    }
    if (r.uploader != 0) {
        w.s("<div class=\"muted\">Загрузил: ");
        c.aLink(r.uploader);
        if (r.date.len > 0) w.f(", {h}", .{r.date});
        w.raw("</div>\n");
    }
    // <audio> понимают новые браузеры; старые покажут ссылку внутри
    w.f("<p><audio controls preload=\"none\" src=\"/v/{d}.mp3\"><a href=\"/v/{d}.mp3\">", .{ id, id });
    w.s("Слушать");
    w.raw("</a></audio></p>\n");
    w.f("<p><a href=\"/v/{d}.mp3\">", .{id});
    w.s("Скачать MP3");
    w.f("</a> <span class=\"muted\">· {s} · {s} МБ · 128 кбит/с</span></p>\n", .{ duration(c, r.seconds), megabytes(c, r.bytes) });
    if (!r.audiobook) {
        // слова и ноты: свои у исполнения или стиха
        const p = if (hasText(r)) pieceOf(c, r.piece) else null;
        const text = if (r.text.len > 0) r.text else if (p) |x| x.text else "";
        const cpro = if (r.text.len > 0) chordpro.looksLike(r.text) else if (p) |x| x.chordpro else false;
        if (text.len > 0) {
            if (r.text.len > 0) w.s("<h3>Слова исполнения</h3>") else w.s("<h3>Слова</h3>");
            if (cpro) chordpro.renderIds(w, text, false) else h.paras(c, text);
        }
        const notes = if (r.notes.len > 0) r.notes else if (p) |x| x.notes else "";
        if (notes.len > 0) w.f("<h3>Ноты (ABC-нотация)</h3><pre class=\"abc\">{h}</pre>", .{notes});
    }
    if (canEdit(c, r)) w.f("<p><a href=\"{U}/v/{d}/edit{E}\">Править или удалить</a></p>\n", .{id});
    c.page(.{ .title = title, .sec = "/v", .crumbs = &.{ .{ .text = T("Записи"), .href = "/v" }, .{ .text = title } } });
}

/// /v/N.mp3: файл записи, целиком или диапазоном (Range) — для перемотки.
pub fn serve(c: *Ctx, id: i32) void {
    _ = c.db.recording(id) orelse return c.notFound();
    var dir = c.app.root.openDir(dir_name, .{}) catch return c.notFound();
    defer dir.close();
    var nb: [24]u8 = undefined;
    const file = dir.openFile(std.fmt.bufPrint(&nb, "{d}.mp3", .{id}) catch return c.notFound(), .{}) catch return c.notFound();
    defer file.close();
    const size = (file.stat() catch return c.notFound()).size;
    c.reply.header("Accept-Ranges: bytes", .{});
    c.reply.header("Content-Disposition: inline; filename=\"{d}.mp3\"", .{id});
    const tag = std.fmt.allocPrint(c.a, "\"v{d}-{d}\"", .{ id, size }) catch "\"v\"";
    c.reply.header("ETag: {s}", .{tag});
    c.reply.header("Cache-Control: max-age=86400", .{});
    if (c.req.if_none_match.len > 0 and std.mem.indexOf(u8, c.req.if_none_match, tag) != null) {
        c.reply.status = 304;
        c.reply.ctype = "audio/mpeg";
        return;
    }
    var lo: u64 = 0;
    var hi: u64 = size;
    var partial = false;
    if (http.parseRange(c.req.range, size)) |rng| {
        if (rng) |x| {
            lo = x[0];
            hi = x[1];
            partial = true;
        }
    } else |_| {
        c.reply.status = 416;
        c.reply.ctype = "audio/mpeg";
        c.reply.header("Content-Range: bytes */{d}", .{size});
        return;
    }
    const buf = c.app.gpa.alloc(u8, @intCast(hi - lo)) catch return c.fail(503, T("Не хватает памяти."));
    const n = file.preadAll(buf, lo) catch 0;
    c.reply.owned = buf;
    if (partial) {
        c.reply.status = 206;
        c.reply.header("Content-Range: bytes {d}-{d}/{d}", .{ lo, lo + n -| 1, size });
    } else c.reply.status = 200;
    c.reply.ctype = "audio/mpeg";
    c.reply.body = buf[0..n];
}

// ───────────── /v/-N ─────────────

pub fn reader(c: *Ctx, id: i32) void {
    const w = &c.w;
    const r = c.db.reader(id) orelse return c.notFound();
    w.f("<h2>{h}</h2><div class=\"muted\">", .{r.name});
    w.s("чтец и исполнитель");
    if (r.years.len > 0) w.f(" · {h}", .{r.years});
    w.f(" · <code>/v/{d}</code></div>\n", .{id});
    if (r.about.len > 0) h.paras(c, r.about);
    if (r.author != 0) {
        w.s("<p>Это автор: ");
        c.aLink(r.author);
        w.raw("</p>\n");
    }
    const users = c.db.usersOfReader(id);
    if (users.len > 0) {
        w.s("<p>Это участник сайта: ");
        for (users, 0..) |u, k| {
            if (k > 0) w.raw(", ");
            w.f("<a href=\"{U}/u/{d}{E}\">{h}</a>", .{ u, c.db.name(u) });
        }
        w.raw("</p>\n");
    }
    var n: usize = 0;
    for (c.db.recordings()) |x| {
        if (x.reader != id) continue;
        if (n == 0) w.s("<h3>Записи</h3><ul>");
        n += 1;
        w.f("<li><a href=\"{U}/v/{d}{E}\">{h}</a> <span class=\"muted\">· ", .{ x.id, titleOf(c, x) });
        subjectLink(c, x);
        w.f(" · {s}</span></li>", .{duration(c, x.seconds)});
    }
    if (n > 0) w.raw("</ul>\n");
    if (canEditReader(c, id)) w.f("<p><a href=\"{U}/v/{d}/edit{E}\">Править</a></p>\n", .{id});
    c.page(.{ .title = r.name, .sec = "/v", .crumbs = &.{ .{ .text = T("Записи"), .href = "/v" }, .{ .text = r.name } } });
}

pub fn readerEditPage(c: *Ctx, id: i32, msg: []const u8) void {
    const w = &c.w;
    const r = c.db.reader(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin?back=/v/{d}/edit", .{id});
    if (!canEditReader(c, id)) return c.denied(T("Править чтеца могут привязанный к нему участник, сотрудник и /u/0."));
    w.f("<h2>Правка: {h}</h2>", .{r.name});
    c.msgBox(msg);
    w.f("<form action=\"/v/{d}/edit\" method=\"post\" class=\"box\">", .{id});
    c.post();
    w.f("\n<table><tr><td>Имя</td><td><input name=\"name\" size=\"40\" value=\"{h}\"></td></tr>\n<tr><td>Годы жизни</td><td><input name=\"years\" size=\"12\" value=\"{h}\"></td></tr>\n<tr><td valign=\"top\">О чтеце</td><td><textarea name=\"about\" rows=\"6\" cols=\"60\" style=\"width:100%\">{h}</textarea></td></tr>\n", .{ r.name, r.years, r.about });
    w.s("<tr><td valign=\"top\">Это автор</td><td>");
    authorSelect(c, r.author);
    w.s("<br><span class=\"muted\">Если чтец — сам автор произведений: его записи помечаются «(автор)», а на странице автора видно, что он читает своё.</span></td></tr>\n");
    w.s("<tr><td></td><td><input type=\"submit\" value=\"Сохранить\"></td></tr></table></form>");
    c.page(.{ .title = T("Правка"), .sec = "/v", .crumbs = &.{ .{ .text = T("Записи"), .href = "/v" }, .{ .text = r.name, .href = std.fmt.allocPrint(c.a, "/v/{d}", .{id}) catch "/v" }, .{ .text = T("Правка") } } });
}

pub fn readerEditPost(c: *Ctx, id: i32) void {
    const old = c.db.reader(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEditReader(c, id)) return c.denied(T("Править чтеца могут привязанный к нему участник, сотрудник и /u/0."));
    const name = std.mem.trim(u8, c.form.get("name"), " \r\n\t");
    if (name.len == 0) {
        c.status = 400;
        return readerEditPage(c, id, T("Нужно имя."));
    }
    const years = std.mem.trim(u8, c.form.get("years"), " ");
    const about = std.mem.trimRight(u8, c.form.get("about"), " \r\n\t");
    const author = std.fmt.parseInt(i32, c.form.get("author"), 10) catch 0;
    if (author != 0 and author != old.author and !authorKnown(c, author)) {
        c.status = 400;
        return readerEditPage(c, id, T("Такого автора нет."));
    }
    c.db.putReader(.{ .id = id, .name = name[0..@min(name.len, 120)], .years = years[0..@min(years.len, 30)], .about = about[0..@min(about.len, 8000)], .author = author });
    c.redirect("/v/{d}", .{id});
}

// ───────────── загрузка ─────────────

/// Автор произведения — участник или человек каталога (/c/N, N > 0).
fn authorKnown(c: *Ctx, id: i32) bool {
    return id > 0 and (c.db.isUser(id) or c.db.s.person(id) != null);
}

/// Выбор автора: «—», я сам, люди каталога.
fn authorSelect(c: *Ctx, cur: i32) void {
    const w = &c.w;
    const s = c.db.s;
    const me: i32 = if (c.me) |m| m.user else 0;
    w.s("<select name=\"author\"><option value=\"\">—</option>");
    if (me > 0) w.f("<option value=\"{d}\"{s}>я сам ({h})</option>", .{ me, if (cur == me) " selected" else "", c.db.name(me) });
    for (s.persons) |x| {
        if (x.id <= 0) continue;
        w.f("<option value=\"{d}\"{s}>{h}", .{ x.id, if (cur == x.id) " selected" else "", s.str(x.name) });
        if (x.years.len > 0) w.f(" ({h})", .{s.str(x.years)});
        w.raw("</option>");
    }
    if (cur != 0 and cur != me and s.person(cur) == null) w.f("<option value=\"{d}\" selected>{h}</option>", .{ cur, c.db.name(cur) });
    w.raw("</select>");
}

fn form(c: *Ctx, action: []const u8, r: ?dbm.Recording) void {
    const w = &c.w;
    const me = c.me.?.user;
    const edit = r != null;
    w.f("<form action=\"{s}\" method=\"post\" class=\"box\"{s}>", .{ action, if (edit) "" else " enctype=\"multipart/form-data\"" });
    c.post();
    w.raw("\n<table>");
    // что записано; номер книги или стиха необязателен
    const book_s = if (r) |x| (if (x.audiobook and x.book >= 0) std.fmt.allocPrint(c.a, "{d}", .{x.book}) catch "" else "") else c.q("book");
    const piece_s = if (r) |x| (if (!x.audiobook and x.piece != 0) std.fmt.allocPrint(c.a, "{d}", .{x.piece}) catch "" else "") else c.q("piece");
    const perf = if (r) |x| !x.audiobook else (piece_s.len > 0 or std.mem.eql(u8, c.q("kind"), "perf"));
    w.s("<tr><td valign=\"top\">Что</td><td>");
    w.f("<label><input type=\"radio\" name=\"kind\" value=\"book\"{s}> аудиокнига; книга номер <input name=\"book\" size=\"6\" value=\"{h}\"></label> <span class=\"muted\">(/b/N)</span><br>", .{ if (perf) "" else " checked", book_s });
    w.f("<label><input type=\"radio\" name=\"kind\" value=\"perf\"{s}> исполнение; стих или песня номер <input name=\"piece\" size=\"6\" value=\"{h}\"></label> <span class=\"muted\">(/p/N)</span><br>", .{ if (perf) " checked" else "", piece_s });
    w.s("<span class=\"muted\">Номер можно оставить пустым: книгу или текст привяжете позже — или выложите их со страницы записи.</span></td></tr>\n");
    // автор — нужен, только пока нет книги или стиха
    w.s("<tr><td valign=\"top\">Автор</td><td>");
    authorSelect(c, if (r) |x| x.author else 0);
    w.s(" или новый: <input name=\"new_author\" size=\"24\"> годы жизни <input name=\"author_years\" size=\"10\"><br><span class=\"muted\">Только для записи без книги или стиха: иначе автор — их автор.</span></td></tr>\n");
    // чтец
    const cur = if (r) |x| x.reader else 0;
    const by_author = if (r) |x| (if (c.db.reader(x.reader)) |rd| rd.author != 0 and rd.author == authorOf(c, x) else false) else false;
    w.s("<tr><td valign=\"top\">Чтец или исполнитель</td><td><select name=\"reader\"><option value=\"\">—</option>");
    const mine = c.db.readersOf(me);
    for (c.db.readers()) |x| {
        var own = false;
        for (mine) |m| own = own or m == x.id;
        w.f("<option value=\"{d}\"{s}>{h}{s}</option>", .{ x.id, if (cur == x.id or (cur == 0 and own)) " selected" else "", x.name, if (own) T(" (это я)") else "" });
    }
    w.s("</select><br>или новый: <input name=\"new_reader\" size=\"24\"> годы жизни <input name=\"years\" size=\"10\"><br><label><input type=\"checkbox\" name=\"me\" value=\"1\"> новый чтец — это я (привязать к моей учётной записи)</label><br>");
    w.f("<label><input type=\"checkbox\" name=\"by_author\" value=\"1\"{s}> читает или исполняет сам автор</label> <span class=\"muted\">(чтец заводится под именем автора и связывается с ним)</span></td></tr>\n", .{if (by_author) " checked" else ""});
    w.f("<tr><td>Название записи</td><td><input name=\"title\" size=\"40\" value=\"{h}\"> <span class=\"muted\">без книги или стиха — обязательно; иначе — как у них</span></td></tr>\n", .{if (r) |x| x.title else ""});
    w.f("<tr><td>Год записи</td><td><input name=\"year\" size=\"6\" value=\"{h}\"></td></tr>\n", .{if (r) |x| x.year else ""});
    source.row(c, if (r) |x| c.db.source('v', x.id) else "");
    if (r == null or !r.?.audiobook) {
        w.f("<tr><td valign=\"top\">Слова исполнения</td><td><textarea name=\"text\" rows=\"8\" cols=\"60\" style=\"width:100%\">{h}</textarea><br>", .{if (r) |x| x.text else ""});
        w.s("<span class=\"muted\">Только для исполнения: если поётся иначе, чем записано в /p/N, или текста на сайте нет. Аккорды — ChordPro: <code>[Am]слова</code>.</span></td></tr>\n");
        w.f("<tr><td valign=\"top\">Ноты</td><td><textarea name=\"notes\" rows=\"4\" cols=\"60\" style=\"width:100%\">{h}</textarea><br>", .{if (r) |x| x.notes else ""});
        w.s("<span class=\"muted\">Необязательно: мелодия исполнения в ABC-нотации.</span></td></tr>\n");
    }
    if (!edit) {
        w.f("<tr><td>Файл</td><td><input type=\"file\" name=\"file\" accept=\"{s}\"><br>", .{acceptList()});
        w.s("<span class=\"muted\">");
        w.s("Принимается MP3");
        if (cfg.ogg) w.s(", Ogg Vorbis");
        if (cfg.m4a) w.s(", M4A (AAC)");
        w.s(". Всё перекодируется в MP3 128 кбит/с (MPEG-1 Layer III), как до 2003 года; до 200 МБ.</span></td></tr>\n");
    }
    w.s("<tr><td></td><td><input type=\"submit\" value=\"Сохранить\"></td></tr></table></form>");
}

pub fn newPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    if (c.me == null) return c.redirect("/signin?back=/v/new", .{});
    if (!mayUpload(c)) return c.denied(T("Нужно право «выкладывать книги»."));
    w.s("<h2>Загрузить запись</h2><p>Аудиокнига или исполнение стиха, песни. Книга или текст необязательны — их можно привязать позже. Чтец или исполнитель обязателен; им может быть сам автор.</p>");
    c.msgBox(msg);
    form(c, "/v/new", null);
    c.page(.{ .title = T("Загрузить запись"), .sec = "/v", .crumbs = &.{ .{ .text = T("Записи"), .href = "/v" }, .{ .text = T("Загрузить") } } });
}

/// Чтец из формы: выбранный или новый; null — не указан.
fn readerFromForm(c: *Ctx) ?i32 {
    const name = std.mem.trim(u8, c.form.get("new_reader"), " \r\n\t");
    if (name.len > 0) {
        const years = std.mem.trim(u8, c.form.get("years"), " ");
        const id = c.db.readerByName(name[0..@min(name.len, 120)], years[0..@min(years.len, 30)]);
        if (id == 0) return null;
        if (c.form.on("me")) {
            const me = c.me.?.user;
            var list = std.ArrayList(i32).init(c.a);
            list.appendSlice(c.db.readersOf(me)) catch {};
            var dup = false;
            for (list.items) |x| dup = dup or x == id;
            if (!dup) list.append(id) catch {};
            c.db.setReadersOf(me, list.items);
        }
        return id;
    }
    const id = std.fmt.parseInt(i32, c.form.get("reader"), 10) catch return null;
    if (id >= 0 or c.db.reader(id) == null) return null;
    return id;
}

/// Чтец записи: «читает сам автор» — чтец, связанный с автором (заводится при
/// нужде); иначе — из списка или новый.
fn readerFor(c: *Ctx, author: i32) ?i32 {
    if (c.form.on("by_author")) {
        if (author == 0) return null;
        const id = c.db.readerOfAuthor(author);
        return if (id < 0) id else null;
    }
    return readerFromForm(c);
}

const no_reader = "Нужен чтец или исполнитель: выберите из списка, впишите имя нового или отметьте «читает сам автор» (тогда нужен автор).";
const no_title = "Без книги или стиха нужно название записи.";

/// Что записано: книга или стих (если указаны) и автор.
const Subject = struct {
    audiobook: bool,
    book: i32 = -1,
    piece: i32 = 0,
    author: i32 = 0,
    title: []const u8 = "",
    album: []const u8 = "",

    fn has(sb: Subject) bool {
        return if (sb.audiobook) sb.book >= 0 else sb.piece != 0;
    }
};

/// Основа и автор из формы; null — ошибка, текст в `msg`.
fn subjectFromForm(c: *Ctx, msg: *[]const u8, old_author: i32) ?Subject {
    var sb = Subject{ .audiobook = !std.mem.eql(u8, c.form.get("kind"), "perf") };
    if (sb.audiobook) {
        const t = std.mem.trim(u8, c.form.get("book"), " /b");
        if (t.len > 0) {
            sb.book = std.fmt.parseInt(i32, t, 10) catch {
                msg.* = T("Номер книги — число (/b/N); можно оставить пустым.");
                return null;
            };
            const b = (if (sb.book >= 0) c.db.s.book(sb.book) else null) orelse {
                msg.* = T("Такой книги в библиотеке нет. Номер можно оставить пустым и привязать книгу позже.");
                return null;
            };
            sb.title = c.db.s.str(b.title);
            sb.album = sb.title;
            sb.author = b.author;
        }
    } else {
        const t = std.mem.trim(u8, c.form.get("piece"), " /p");
        if (t.len > 0) {
            sb.piece = std.fmt.parseInt(i32, t, 10) catch 0;
            const p = (if (sb.piece != 0) pieceOf(c, sb.piece) else null) orelse {
                msg.* = T("Такого стиха или песни нет. Номер можно оставить пустым и привязать текст позже.");
                return null;
            };
            sb.title = p.title;
            sb.author = p.author;
        }
    }
    if (sb.has()) return sb;
    const nm = std.mem.trim(u8, c.form.get("new_author"), " \r\n\t");
    if (nm.len > 0) {
        const years = std.mem.trim(u8, c.form.get("author_years"), " ");
        sb.author = c.db.personByName(nm[0..@min(nm.len, 120)], years[0..@min(years.len, 30)], "");
        if (sb.author == 0) {
            msg.* = T("Автор не заведён.");
            return null;
        }
        c.app.rebuild_wanted = true;
        return sb;
    }
    const a = std.fmt.parseInt(i32, c.form.get("author"), 10) catch 0;
    if (a != 0 and a != old_author and !authorKnown(c, a)) {
        msg.* = T("Такого автора нет.");
        return null;
    }
    sb.author = a;
    return sb;
}

fn bad(c: *Ctx, msg: []const u8) void {
    c.status = 400;
    newPage(c, msg);
}

pub fn newPost(c: *Ctx) void {
    if (c.me == null) return c.redirect("/signin?back=/v/new", .{});
    if (!mayUpload(c)) return c.denied(T("Нужно право «выкладывать книги»."));
    var msg: []const u8 = "";
    const sb = subjectFromForm(c, &msg, 0) orelse return bad(c, msg);
    const f = c.form.file("file") orelse return bad(c, T("Нужен файл записи."));
    if (f.value.len == 0) return bad(c, T("Нужен файл записи."));
    const kind = audio.detect(f.value) orelse return bad(c, T("Файл не похож на MP3, Ogg Vorbis или M4A."));
    if (!kindAllowed(kind)) return bad(c, T("Этот формат на сайте не принимается: сборка без него."));
    const title_in = std.mem.trim(u8, c.form.get("title"), " \r\n\t");
    if (!sb.has() and title_in.len == 0) return bad(c, T(no_title));
    const rid = readerFor(c, sb.author) orelse return bad(c, T(no_reader));
    const year = std.mem.trim(u8, c.form.get("year"), " ");
    const title = title_in[0..@min(title_in.len, 200)];
    // номер и файл
    var dir = c.app.root.makeOpenPath(dir_name, .{}) catch return c.fail(500, T("Папка записей недоступна."));
    defer dir.close();
    var id: i32 = undefined;
    var nb: [24]u8 = undefined;
    while (true) {
        id = c.db.nextId("recording", 1, 1);
        if (c.db.recording(id) != null) continue;
        dir.access(std.fmt.bufPrint(&nb, "{d}.mp3", .{id}) catch unreachable, .{}) catch break;
    }
    const name = std.fmt.bufPrint(&nb, "{d}.mp3", .{id}) catch unreachable;
    var tb: [32]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{d}.mp3.tmp", .{id}) catch unreachable;
    const res = convert(c, dir, tmp, f.value, .{
        .title = if (title.len > 0) title else sb.title,
        .artist = (c.db.reader(rid) orelse dbm.Reader{ .id = rid, .name = "" }).name,
        .album = sb.album,
        .year = year,
        .comment = c.app.name,
        .genre = if (sb.audiobook) 101 else 255,
    }) catch |e| {
        dir.deleteFile(tmp) catch {};
        return bad(c, switch (e) {
            error.NotAudio => T("Файл не похож на MP3, Ogg Vorbis или M4A."),
            error.Unsupported => T("Такой вариант формата не поддерживается (например, HE-AAC без ядра LC, Vorbis с полом 0, частота вне 4–192 кГц)."),
            error.TooLong => T("Запись длиннее суток."),
            error.OutOfMemory => T("Не хватает памяти."),
            else => T("Файл повреждён: звук не разобрался."),
        });
    };
    dir.rename(tmp, name) catch {
        dir.deleteFile(tmp) catch {};
        return c.fail(500, T("Файл не сохранён."));
    };
    var text = std.mem.trimRight(u8, c.form.get("text"), " \r\n\t");
    var notes = std.mem.trimRight(u8, c.form.get("notes"), " \r\n\t");
    if (sb.audiobook) {
        text = "";
        notes = "";
    }
    c.db.putRecording(.{
        .id = id,
        .title = title,
        .reader = rid,
        .audiobook = sb.audiobook,
        .book = sb.book,
        .piece = sb.piece,
        .text = text,
        .notes = notes,
        .uploader = c.me.?.user,
        .date = c.today(),
        .seconds = res.seconds(),
        .bytes = res.bytes,
        .year = year[0..@min(year.len, 10)],
        .author = if (sb.has()) 0 else sb.author,
    });
    source.save(c, 'v', id);
    c.redirect("/v/{d}", .{id});
}

fn convert(c: *Ctx, dir: std.fs.Dir, tmp: []const u8, data: []const u8, tag: audio.Tag) audio.Error!audio.Result {
    const file = dir.createFile(tmp, .{}) catch return error.WriteFailed;
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const r = try audio.toMp3(c.app.gpa, data, bw.writer().any(), tag);
    bw.flush() catch return error.WriteFailed;
    return r;
}

// ───────────── правка и удаление ─────────────

pub fn editPage(c: *Ctx, id: i32, msg: []const u8) void {
    const w = &c.w;
    const r = c.db.recording(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin?back=/v/{d}/edit", .{id});
    if (!canEdit(c, r)) return c.denied(T("Править может тот, кто загрузил, привязанный к чтецу участник, сотрудник или /u/0."));
    const title = titleOf(c, r);
    w.f("<h2>Правка: {h}</h2>", .{title});
    c.msgBox(msg);
    form(c, std.fmt.allocPrint(c.a, "/v/{d}/edit", .{id}) catch "/v", r);
    w.f("\n<form action=\"/v/{d}/delete\" method=\"post\" class=\"box\">", .{id});
    c.post();
    w.s("<label><input type=\"checkbox\" name=\"sure\" value=\"1\"> да, удалить запись и файл насовсем</label> <input type=\"submit\" value=\"Удалить\"></form>");
    c.page(.{ .title = T("Правка"), .sec = "/v", .crumbs = &.{ .{ .text = T("Записи"), .href = "/v" }, .{ .text = title, .href = std.fmt.allocPrint(c.a, "/v/{d}", .{id}) catch "/v" }, .{ .text = T("Правка") } } });
}

pub fn editPost(c: *Ctx, id: i32) void {
    var r = c.db.recording(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEdit(c, r)) return c.denied(T("Править может тот, кто загрузил, привязанный к чтецу участник, сотрудник или /u/0."));
    var msg: []const u8 = "";
    const sb = subjectFromForm(c, &msg, r.author) orelse {
        c.status = 400;
        return editPage(c, id, msg);
    };
    const title = std.mem.trim(u8, c.form.get("title"), " \r\n\t");
    if (!sb.has() and title.len == 0) {
        c.status = 400;
        return editPage(c, id, T(no_title));
    }
    r.reader = readerFor(c, sb.author) orelse {
        c.status = 400;
        return editPage(c, id, T(no_reader));
    };
    const year = std.mem.trim(u8, c.form.get("year"), " ");
    r.title = title[0..@min(title.len, 200)];
    r.year = year[0..@min(year.len, 10)];
    r.audiobook = sb.audiobook;
    r.book = sb.book;
    r.piece = sb.piece;
    r.author = if (sb.has()) 0 else sb.author;
    if (!r.audiobook) {
        r.text = std.mem.trimRight(u8, c.form.get("text"), " \r\n\t");
        r.notes = std.mem.trimRight(u8, c.form.get("notes"), " \r\n\t");
    } else {
        r.text = "";
        r.notes = "";
    }
    c.db.putRecording(r);
    source.save(c, 'v', id);
    c.redirect("/v/{d}", .{id});
}

pub fn deletePost(c: *Ctx, id: i32) void {
    const r = c.db.recording(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEdit(c, r)) return c.denied(T("Удалить может тот, кто загрузил, привязанный к чтецу участник, сотрудник или /u/0."));
    if (!c.form.on("sure")) {
        c.status = 400;
        return editPage(c, id, T("Отметьте «да, удалить запись и файл насовсем»."));
    }
    if (c.app.root.openDir(dir_name, .{})) |dir_c| {
        var dir = dir_c;
        defer dir.close();
        var nb: [24]u8 = undefined;
        dir.deleteFile(std.fmt.bufPrint(&nb, "{d}.mp3", .{id}) catch unreachable) catch {};
    } else |_| {}
    c.db.delRecording(id);
    c.db.setSource('v', id, "");
    c.redirect("/v", .{});
}

// ───────────── связи с книгами, стихами, участниками ─────────────

/// Записи этого вида без книги или стиха, которые участник может править.
fn unlinked(c: *Ctx, audiobook: bool) []dbm.Recording {
    var out = std.ArrayList(dbm.Recording).init(c.a);
    if (c.me == null) return out.items;
    for (c.db.recordings()) |r| {
        if (r.audiobook == audiobook and !hasText(r) and canEdit(c, r)) out.append(r) catch break;
    }
    return out.items;
}

/// Записи книги или стиха, ссылка «загрузить» и форма «привязать запись без основы».
fn forText(c: *Ctx, audiobook: bool, target: i32) void {
    const w = &c.w;
    var n: usize = 0;
    for (c.db.recordings()) |r| {
        if (r.audiobook != audiobook or !hasText(r) or (if (audiobook) r.book else r.piece) != target) continue;
        if (n == 0) {
            if (audiobook) w.s("\n<h3>Аудиокниги</h3><ul>") else w.s("\n<h3>Исполнения</h3><ul>");
        }
        n += 1;
        w.f("<li><a href=\"{U}/v/{d}{E}\">{h}</a> <span class=\"muted\">· ", .{ r.id, titleOf(c, r) });
        if (audiobook) w.s("читает ") else w.s("исполняет ");
        readerOfRec(c, r);
        w.f(" · {s}</span></li>", .{duration(c, r.seconds)});
    }
    if (n > 0) w.raw("</ul>\n");
    if (mayUpload(c)) {
        if (audiobook) w.f("<p><a href=\"{U}/v/new?book={d}\">Загрузить аудиокнигу</a></p>\n", .{target}) else w.f("<p><a href=\"{U}/v/new?piece={d}\">Загрузить исполнение</a></p>\n", .{target});
    }
    const free = unlinked(c, audiobook);
    if (free.len == 0) return;
    w.f("<form action=\"/{s}/{d}/voice\" method=\"post\" class=\"box\">", .{ if (audiobook) "b" else "p", target });
    c.post();
    if (audiobook) w.s("Привязать аудиокнигу, выложенную без книги: ") else w.s("Привязать исполнение, выложенное без текста: ");
    w.raw("<select name=\"rec\">");
    for (free) |r| {
        w.f("<option value=\"{d}\">/v/{d} {h} — ", .{ r.id, r.id, titleOf(c, r) });
        w.esc(if (c.db.reader(r.reader)) |x| x.name else "");
        w.raw("</option>");
    }
    w.s("</select> <input type=\"submit\" value=\"Привязать\"></form>\n");
}

/// На странице книги: её аудиокниги.
pub fn forBook(c: *Ctx, book: i32) void {
    if (!enabled or !c.secListed(.v)) return;
    forText(c, true, book);
}

/// На странице стиха или песни: исполнения.
pub fn forPiece(c: *Ctx, piece: i32) void {
    if (!enabled or !c.secListed(.v)) return;
    forText(c, false, piece);
}

/// POST /b/N/voice и /p/N/voice: привязать запись без основы к книге или стиху.
pub fn linkPost(c: *Ctx, kind: u8, target: i32) void {
    if (c.me == null) return c.redirect("/signin", .{});
    if (!c.secWritable(.v)) return c.denied(T("Раздел записей закрыт на запись."));
    const rid = std.fmt.parseInt(i32, c.form.get("rec"), 10) catch return c.notFound();
    var r = c.db.recording(rid) orelse return c.notFound();
    if (!canEdit(c, r)) return c.denied(T("Привязать может тот, кто загрузил запись, привязанный к чтецу участник, сотрудник или /u/0."));
    if (hasText(r) or r.audiobook != (kind == 'b')) return c.fail(400, T("Запись уже привязана или другого вида."));
    if (kind == 'b') {
        if (target < 0 or c.db.s.book(target) == null) return c.notFound();
        r.book = target;
    } else {
        if (pieceOf(c, target) == null) return c.notFound();
        r.piece = target;
    }
    r.author = 0;
    c.db.putRecording(r);
    c.redirect("/v/{d}", .{rid});
}

/// Книга или стих выложены со страницы записи (поле voice=N): привязать запись к ним.
/// Автор записи остаётся, пока книга не появится в каталоге (снимок пересобирается).
pub fn attachNew(c: *Ctx, kind: u8, target: i32) void {
    if (!enabled) return;
    const rid = std.fmt.parseInt(i32, c.form.get("voice"), 10) catch return;
    var r = c.db.recording(rid) orelse return;
    if (!canEdit(c, r) or hasText(r) or r.audiobook != (kind == 'b')) return;
    if (kind == 'b') r.book = target else r.piece = target;
    c.db.putRecording(r);
}

/// Скрытое поле voice=N в форме книги или стиха, выкладываемых со страницы записи.
pub fn voiceField(c: *Ctx) void {
    if (!enabled) return;
    const rid = std.fmt.parseInt(i32, c.q("voice"), 10) catch return;
    const r = c.db.recording(rid) orelse return;
    if (!canEdit(c, r) or hasText(r)) return;
    c.w.f("<input type=\"hidden\" name=\"voice\" value=\"{d}\">", .{rid});
    c.w.f("<p class=\"muted\">После публикации запись <a href=\"{U}/v/{d}{E}\">{h}</a> будет привязана к ней.</p>", .{ rid, titleOf(c, r) });
}

/// Автор записи без основы, выкладывающей текст (?voice=N): чтобы подставить в форму.
pub fn voiceAuthor(c: *Ctx) i32 {
    if (!enabled) return 0;
    const rid = std.fmt.parseInt(i32, c.q("voice"), 10) catch return 0;
    const r = c.db.recording(rid) orelse return 0;
    return r.author;
}

/// На странице автора: чтецы, которые и есть он, и записи его произведений.
pub fn forAuthor(c: *Ctx, pid: i32) void {
    if (!enabled or !c.secListed(.v)) return;
    const w = &c.w;
    var k: usize = 0;
    for (c.db.readers()) |r| {
        if (r.author != pid) continue;
        if (k == 0) w.s("<p>Читает и исполняет своё: ") else w.raw(", ");
        k += 1;
        readerLink(c, r.id);
    }
    if (k > 0) w.raw("</p>\n");
    var n: usize = 0;
    for (c.db.recordings()) |r| {
        if (authorOf(c, r) != pid) continue;
        if (n == 0) w.s("\n<h3>Записи</h3><ul>");
        n += 1;
        w.f("<li><a href=\"{U}/v/{d}{E}\">{h}</a> <span class=\"muted\">· {s} · ", .{ r.id, titleOf(c, r), if (r.audiobook) T("аудиокнига") else T("исполнение") });
        readerOfRec(c, r);
        w.f(" · {s}</span></li>", .{duration(c, r.seconds)});
    }
    if (n > 0) w.raw("</ul>\n");
}

/// На странице участника: кто он среди чтецов (всем) и форма привязки (сотрудник и /u/0).
pub fn userReaders(c: *Ctx, uid: i32) void {
    if (!enabled or !c.secListed(.v)) return;
    const w = &c.w;
    const bound = c.db.readersOf(uid);
    if (bound.len > 0) {
        w.s("<p>Чтец на сайте: ");
        for (bound, 0..) |r, k| {
            if (k > 0) w.raw(", ");
            readerLink(c, r);
        }
        w.raw("</p>\n");
    }
    if (!c.isModerator() or uid == 0 or !c.secWritable(.v)) return;
    const all = c.db.readers();
    if (all.len == 0 and bound.len == 0) return;
    w.f("<form action=\"/u/{d}/readers\" method=\"post\" class=\"box\">", .{uid});
    c.post();
    w.s("<b>Привязка к чтецам</b> <span class=\"muted\">(участник сможет править записи чтеца и его страницу)</span><br>\n");
    for (bound) |r| {
        w.f("<label><input type=\"checkbox\" name=\"keep\" value=\"{d}\" checked> ", .{r});
        if (c.db.reader(r)) |x| w.esc(x.name) else w.f("#{d}", .{r});
        w.raw("</label><br>\n");
    }
    w.s("Добавить: <select name=\"add\"><option value=\"\">—</option>");
    for (all) |x| {
        var dup = false;
        for (bound) |r| dup = dup or r == x.id;
        if (dup) continue;
        w.f("<option value=\"{d}\">{h}</option>", .{ x.id, x.name });
    }
    w.s("</select> <input type=\"submit\" value=\"Сохранить\"></form>\n");
}

pub fn readersPost(c: *Ctx, uid: i32) void {
    if (c.me == null) return c.redirect("/signin", .{});
    if (!c.isModerator() or !c.secWritable(.v)) return c.denied(T("Привязывать участников к чтецам могут сотрудник и /u/0."));
    if (uid == 0 or c.db.user(uid) == null) return c.notFound();
    var ids = std.ArrayList(i32).init(c.a);
    for (c.form.fields) |f| {
        if (!std.mem.eql(u8, f.name, "keep")) continue;
        const id = std.fmt.parseInt(i32, f.value, 10) catch continue;
        if (id < 0 and c.db.reader(id) != null) ids.append(id) catch {};
    }
    if (std.fmt.parseInt(i32, c.form.get("add"), 10)) |id| {
        var dup = false;
        for (ids.items) |x| dup = dup or x == id;
        if (id < 0 and !dup and c.db.reader(id) != null) ids.append(id) catch {};
    } else |_| {}
    c.db.setReadersOf(uid, ids.items);
    c.redirect("/u/{d}", .{uid});
}
