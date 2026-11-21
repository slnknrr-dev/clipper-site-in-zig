//! Книги и серии (/b), чтение (/b/N/K, /q/N), комментарии, выкладывание.

const std = @import("std");
const cp = @import("../cp1251.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const fb2 = @import("../fb2.zig");
const snapshot = @import("../snapshot.zig");
const library = @import("../library.zig");
const import = @import("../import.zig");
const W = @import("../out.zig").W;
const Ctx = @import("../app.zig").Ctx;
const h = @import("h.zig");
const marks = @import("marks.zig");
const source = @import("source.zig");
const voice = @import("voice.zig");

const T = cp.text;
const per_page = 500;

pub fn index(c: *Ctx) void {
    const w = &c.w;
    const s = c.db.s;
    if (c.featureOpen(.upload)) w.f("<p><a href=\"{U}/b/upload{E}\"><b>+ Выложить книгу</b></a></p>", .{});
    w.s("<h2>Серии</h2>");
    var t = h.Table.begin(c, &.{ "№", "Серия", "Автор", "Книг" });
    for (s.series) |x| {
        t.row();
        w.raw("<td>");
        c.sign(x.id);
        w.f("</td><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ x.id, s.str(x.title) });
        c.aLink(x.author);
        w.f("</td><td>{d}</td></tr>", .{x.books.len});
    }
    t.end();
    w.s("\n<h2>Книги</h2>");
    // большая библиотека листается по 500 книг
    const pages = (s.books.len + per_page - 1) / per_page;
    const pg: usize = @intCast(std.math.clamp(c.qInt("pg"), 1, @as(i64, @intCast(@max(pages, 1)))));
    t = h.Table.begin(c, &.{ "№", "Название", "Автор", "Год", "" });
    var k = (pg - 1) * per_page;
    while (k < @min(s.books.len, pg * per_page)) : (k += 1) {
        const b = s.bookAt(k);
        t.row();
        w.f("<td>{d}</td><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ b.id, b.id, s.str(b.title) });
        c.bookAuthor(b.id, b.author);
        w.f("</td><td>{h}</td><td><a href=\"{U}/q/{d}{E}\">читать</a></td></tr>", .{ s.str(b.year), b.id });
    }
    t.end();
    if (pages > 1) {
        w.raw("<p class=\"pager\">");
        var i: usize = 1;
        while (i <= pages) : (i += 1) {
            if (i == pg) w.f("<b>{d}</b>", .{i}) else w.f("<a href=\"{U}/b?pg={d}{E}\">{d}</a>", .{ i, i });
        }
        w.raw("</p>");
    }
    c.page(.{ .title = T("Книги"), .sec = "/b", .crumbs = &.{.{ .text = T("Книги") }} });
}

fn seriesPage(c: *Ctx, id: i32) void {
    const w = &c.w;
    const s = c.db.s;
    const x = s.oneSeries(id) orelse return c.notFound();
    const title = s.str(x.title);
    w.f("<h2>Серия: {h}</h2><div class=\"muted\">", .{title});
    c.aLink(x.author);
    w.f(" · <code>/b/{d}</code></div><p>{h}</p>\n", .{ id, s.str(x.about) });
    var t = h.Table.begin(c, &.{ "#", "Книга", "Год", "" });
    for (s.ids(x.books), 0..) |bid, i| {
        const b = s.book(bid) orelse continue;
        t.row();
        w.f("<td>{d}</td><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>{h}</td><td><a href=\"{U}/q/{d}{E}\">читать</a></td></tr>", .{ i + 1, b.id, s.str(b.title), s.str(b.year), b.id });
    }
    t.end();
    c.page(.{ .title = title, .sec = "/b", .crumbs = &.{ .{ .text = T("Книги"), .href = "/b" }, .{ .text = std.fmt.allocPrint(c.a, "{s}{s}", .{ T("Серия: "), title }) catch title } } });
}

/// Место обложки на странице книги.
const cover_w = 300;
const cover_h = 400;

/// /img/b/{имя} — картинка книги из хранилища: имя меняется вместе с содержимым,
/// поэтому кэшируется надолго.
pub fn bookImage(c: *Ctx, name: []const u8) void {
    const imgstore = @import("../imgstore.zig");
    _, const kind = imgstore.parseName(name) orelse return c.notFound();
    var dir = c.app.img.openDir(imgstore.dir_name, .{}) catch return c.notFound();
    defer dir.close();
    const bytes = dir.readFileAlloc(c.app.gpa, name, 8 << 20) catch return c.notFound();
    c.reply.owned = bytes;
    c.reply.header("Cache-Control: max-age=31536000, immutable", .{});
    c.reply.header("X-Content-Type-Options: nosniff", .{});
    c.send(@import("../img/image.zig").mime(kind), bytes);
}

pub fn book(c: *Ctx, id: i32) void {
    if (id < 0) return seriesPage(c, id);
    const w = &c.w;
    const s = c.db.s;
    const b = s.book(id) orelse return c.notFound();
    const title = s.str(b.title);
    const ser = if (b.series != 0) s.oneSeries(b.series) else null;
    const st = c.app.stat(c.db, id);
    w.f("<h2>{h}</h2>\n<div class=\"muted\">", .{title});
    c.bookAuthor(id, b.author);
    if (b.year.len > 0) w.f(" · {h}", .{s.str(b.year)});
    if (ser) |x| w.f(" · серия <a href=\"{U}/b/{d}{E}\">{h}</a>", .{ x.id, s.str(x.title) });
    w.f(" · <code>/b/{d}</code> · прочтений: {d} · скачиваний: {d}</div>\n", .{ id, st.reads, st.downloads });
    if (s.cover(b)) |im| h.figure(c, im, cover_w, cover_h);
    source.show(c, 'b', id);
    w.f("<div class=\"box\"><b>Аннотация:</b> {h}</div>\n", .{s.str(b.annotation)});
    const from = s.ids(b.drafts);
    if (from.len > 0 and c.secListed(.d)) {
        w.s("<p class=\"muted\">Собрана из черновиков: ");
        for (from, 0..) |d, i| {
            if (i > 0) w.raw(", ");
            if (c.secListed(.d)) w.f("<a href=\"{U}/d/{d}{E}\">/d/{d}</a>", .{ d, d }) else w.f("/d/{d}", .{d});
        }
        w.raw("</p>");
    }
    if (b.uploader != 0) {
        w.s("\n<p class=\"muted\">Выложил: ");
        c.aLink(b.uploader);
        w.raw("</p>");
    }
    w.f("\n<p><a href=\"{U}/b/{d}/1{E}\"><b>&gt;&gt; Читать</b></a> · скачать: ", .{id});
    if (c.featureOpen(.downloads)) {
        w.f("<a href=\"{U}/b/{d}/txt{E}\">txt</a> · <a href=\"{U}/b/{d}/fb2{E}\">fb2</a> · <a href=\"{U}/b/{d}/epub{E}\">epub</a>", .{ id, id, id });
    } else w.s("<span class=\"muted\">скачивание отключено</span>");
    w.s("</p>\n<h3>Оглавление</h3><ol>");
    for (s.bookPages(b), 0..) |pg, i| w.f("<li><a href=\"{U}/b/{d}/{d}{E}\">{h}</a></li>", .{ id, i + 1, s.str(pg.title) });
    w.raw("</ol>\n");
    voice.forBook(c, id);
    if (canEditBook(c, b.*)) {
        w.f("\n<form action=\"/b/{d}/source\" method=\"post\" class=\"box\">", .{id});
        c.post();
        w.f("Источник: <input name=\"source\" size=\"40\" value=\"{h}\"> <input type=\"submit\" value=\"Сохранить\"> <span class=\"muted\">адрес или название: mrakopedia, arxiv, habr…</span></form>\n", .{c.db.source('b', id)});
    }
    comments(c, b);
    if (c.featureOn(.embed) and st.embed) {
        w.s("\n<h3>Встроить на свой сайт</h3><textarea rows=\"2\" cols=\"70\" readonly style=\"width:100%\">&lt;iframe src=&quot;");
        c.origin(w);
        w.f("/e/b/{d}&quot; width=&quot;300&quot; height=&quot;160&quot; frameborder=&quot;0&quot;&gt;&lt;/iframe&gt;</textarea>\n<p class=\"muted\">Глава: <code>/e/b/{d}?ch=1</code> · бейджи: <img src=\"/x/b/reads.svg?id={d}\" alt=\"reads\" align=\"absmiddle\"> <img src=\"/x/b/comments.png?id={d}\" alt=\"comments\" align=\"absmiddle\"> (<code>/x/b/reads.svg?id={d}</code>, без расширения — JSON)</p>", .{ id, id, id, id, id });
    }
    var crumbs = std.ArrayList(@import("../app.zig").Crumb).init(c.a);
    crumbs.append(.{ .text = T("Книги"), .href = "/b" }) catch {};
    if (ser) |x| crumbs.append(.{ .text = s.str(x.title), .href = std.fmt.allocPrint(c.a, "/b/{d}", .{x.id}) catch "/b" }) catch {};
    crumbs.append(.{ .text = title }) catch {};
    c.page(.{ .title = title, .sec = "/b", .crumbs = crumbs.items });
}

// ───────────── комментарии: /b/N/-n и /b/N/-родитель-n, глубина не больше 2 ─────────────

fn cRef(c: *Ctx, x: dbm.Comment) void {
    if (x.parent != 0) c.w.f("-{d}-{d}", .{ x.parent, x.id }) else c.w.f("-{d}", .{x.id});
}

fn cItem(c: *Ctx, b: *const snapshot.Book, x: dbm.Comment) void {
    const w = &c.w;
    w.f("<div class=\"box\"><a name=\"c{d}\"></a>", .{x.id});
    c.aLink(x.author);
    w.f(" <span class=\"muted\">{h} · <a href=\"{U}/b/{d}/", .{ x.date, b.id });
    cRef(c, x);
    w.linkEnd();
    w.raw("\">");
    cRef(c, x);
    w.f("</a></span><br>{b}</div>", .{x.text});
}

fn commentForm(c: *Ctx, b: *const snapshot.Book, parent: i32) void {
    const w = &c.w;
    if (!c.featureOpen(.comments)) return w.s("<p class=\"muted\">Комментарии отключены.</p>");
    if (!h.gate(c, dbm.rights.comment, .comments)) return;
    w.f("<form action=\"/b/{d}/comment\" method=\"post\" class=\"box\">", .{b.id});
    c.post();
    if (parent != 0) w.f("<input type=\"hidden\" name=\"parent\" value=\"{d}\">Ответ на -{d}<br>", .{ parent, parent });
    w.raw("<textarea name=\"text\" rows=\"3\" cols=\"60\" style=\"width:100%\"></textarea><br><input type=\"submit\" value=\"");
    if (parent != 0) w.s("Ответить") else w.s("Комментировать");
    w.raw("\"></form>");
}

fn comments(c: *Ctx, b: *const snapshot.Book) void {
    const w = &c.w;
    if (!c.featureOpen(.comments)) return;
    const list = c.db.comments(b.id);
    w.f("<h3>Комментарии ({d})</h3>", .{list.len});
    for (list) |t| {
        if (t.parent != 0) continue;
        cItem(c, b, t);
        w.raw("<div style=\"margin-left:30px\">");
        for (list) |r| if (r.parent == t.id) cItem(c, b, r);
        w.f("<a class=\"muted\" href=\"{U}/b/{d}/-{d}{E}\">ответить</a></div>", .{ b.id, t.id });
    }
    commentForm(c, b, 0);
}

/// `a` — первое число, `z` — второе. -a: любой комментарий; -a-z: z должен быть ответом на a.
pub fn comment(c: *Ctx, id: i32, a: i32, z: ?i32) void {
    const w = &c.w;
    const s = c.db.s;
    const b = s.book(id) orelse return c.notFound();
    if (!c.featureOpen(.comments)) return c.notFound();
    const list = c.db.comments(id);
    const want = z orelse a;
    var found: ?dbm.Comment = null;
    for (list) |x| if (x.id == want) {
        found = x;
    };
    const x = found orelse return c.notFound();
    if (z != null and x.parent != a) return c.notFound(); // ложные связки вроде -1-1 или -3-2
    var parent: ?dbm.Comment = null;
    if (x.parent != 0) for (list) |k| if (k.id == x.parent) {
        parent = k;
    };
    const title = s.str(b.title);
    w.s("<h2>Комментарий ");
    cRef(c, x);
    w.f("</h2>\n<p class=\"muted\">к книге <a href=\"{U}/b/{d}{E}\">{h}</a> · постоянная ссылка <code>/b/{d}/", .{ id, title, id });
    cRef(c, x);
    w.raw("</code></p>\n");
    if (parent) |p| {
        w.s("<p class=\"muted\">в ответ на:</p>");
        cItem(c, b, p);
        w.raw("<div style=\"margin-left:30px\">");
    }
    cItem(c, b, x);
    if (parent != null) w.raw("</div>");
    var any = false;
    for (list) |r| if (r.parent == x.id) {
        if (!any) w.raw("\n<div style=\"margin-left:30px\">");
        any = true;
        cItem(c, b, r);
    };
    if (any) w.raw("</div>");
    if (x.parent != 0) w.f("\n<p class=\"muted\">Глубина ответов — не больше 2: ответ уйдёт в ветку -{d}.</p>", .{x.parent});
    w.byte('\n');
    commentForm(c, b, if (x.parent != 0) x.parent else x.id);
    c.page(.{ .title = std.fmt.allocPrint(c.a, "{s}{s}", .{ T("Комментарий к "), title }) catch title, .sec = "/b", .crumbs = &.{
        .{ .text = T("Книги"), .href = "/b" },
        .{ .text = title, .href = std.fmt.allocPrint(c.a, "/b/{d}", .{id}) catch "/b" },
        .{ .text = T("Комментарий") },
    } });
}

pub fn commentPost(c: *Ctx, book_s: []const u8) void {
    for (book_s) |ch| if (ch < '0' or ch > '9') return c.notFound();
    const id = std.fmt.parseInt(i32, book_s, 10) catch return c.notFound();
    _ = c.db.s.book(id) orelse return c.notFound();
    if (!c.can(dbm.rights.comment, .comments)) return c.denied(T("Нет права комментировать или комментарии отключены."));
    const list = c.db.comments(id);
    var parent: i32 = std.math.cast(i32, c.form.int("parent") orelse 0) orelse 0;
    var max: i32 = 0;
    var pc: ?dbm.Comment = null;
    for (list) |x| {
        max = @max(max, x.id);
        if (parent != 0 and x.id == parent) pc = x;
    }
    if (parent != 0) {
        const p = pc orelse return c.notFound();
        if (p.parent != 0) parent = p.parent; // глубина не больше 2: ответ на ответ уходит в корневую ветку
    }
    const text = c.form.get("text");
    if (text.len == 0) return c.redirect("/b/{d}", .{id});
    const cid = max + 1;
    c.db.putComment(id, .{ .id = cid, .parent = parent, .author = c.me.?.user, .date = c.today(), .text = text });
    if (parent != 0) c.redirect("/b/{d}/-{d}-{d}", .{ id, parent, cid }) else c.redirect("/b/{d}/-{d}", .{ id, cid });
}

// ───────────── чтение ─────────────

/// Страница чтения K: /b/N/K (и /q/N?ch=K).
pub fn read(c: *Ctx, id: i32, k_arg: ?u32) void {
    const w = &c.w;
    const s = c.db.s;
    const b = s.book(id) orelse return c.notFound();
    if (b.n_pages == 0) return c.notFound();
    var n: u32 = undefined;
    if (k_arg) |k| {
        if (k < 1 or k > b.n_pages) return c.notFound();
        n = k;
    } else {
        const ch = c.qInt("ch");
        n = @intCast(std.math.clamp(if (ch == 0) 1 else ch, 1, @as(i64, b.n_pages)));
    }
    const pages = s.bookPages(b);
    const title = s.str(b.title);
    const ch_title = s.str(pages[n - 1].title);
    const text = c.app.pageText(c.a, b, n - 1) catch return c.fail(500, T("Текст книги не читается."));

    const pager_at = w.n;
    w.raw("<p class=\"pager\" align=\"center\">");
    if (n > 1) w.f("<a href=\"{U}/b/{d}/{d}{E}\">&laquo; назад</a>", .{ id, n - 1 });
    w.byte(' ');
    for (0..b.n_pages) |i| {
        if (i > 0) w.byte(' ');
        if (i + 1 == n) w.f("<b>{d}</b>", .{i + 1}) else w.f("<a href=\"{U}/b/{d}/{d}{E}\">{d}</a>", .{ id, i + 1, i + 1 });
    }
    w.byte(' ');
    if (n < b.n_pages) w.f("<a href=\"{U}/b/{d}/{d}{E}\">вперёд &raquo;</a>", .{ id, n + 1 });
    w.raw("</p>");
    const pager = c.a.dupe(u8, w.buf[pager_at..w.n]) catch "";
    w.f("<h2 align=\"center\">{h}</h2><h3 align=\"center\">{h}</h3>", .{ title, ch_title });
    marks.readingText(c, b, n, text);
    w.raw(pager);

    // оглавление в боковую колонку
    const side_buf = c.a.alloc(u8, 256 + @as(usize, b.n_pages) * 420) catch return c.fail(500, T("Не хватает памяти."));
    var sw = W.init(side_buf);
    sw.tm = w.tm;
    for (pages, 0..) |pg, i| {
        if (i > 0) sw.raw("<br>\n");
        sw.f("<a href=\"{U}/b/{d}/{d}{E}\">", .{ id, i + 1 });
        if (i + 1 == n) sw.f("<b>{h}</b>", .{s.str(pg.title)}) else sw.esc(s.str(pg.title));
        sw.raw("</a>");
    }
    c.page(.{
        .title = std.fmt.allocPrint(c.a, "{s} \x97 {s}", .{ title, ch_title }) catch title,
        .sec = "/b",
        .crumbs = &.{
            .{ .text = T("Книги"), .href = "/b" },
            .{ .text = title, .href = std.fmt.allocPrint(c.a, "/b/{d}", .{id}) catch "/b" },
            .{ .text = std.fmt.allocPrint(c.a, "{s}{s}", .{ T("Чтение: "), ch_title }) catch ch_title },
        },
        .side_head = T("Оглавление"),
        .side = sw.out(),
    });
}

// ───────────── /b/upload ─────────────

const UploadKind = struct { kind: import.Kind, ext: []const u8, mime: []const u8 };
/// В порядке, в каком форматы названы на странице.
const upload_kinds = [_]UploadKind{
    .{ .kind = .txt, .ext = ".txt", .mime = "text/plain" },
    .{ .kind = .fb2, .ext = ".fb2", .mime = "" },
    .{ .kind = .epub, .ext = ".epub", .mime = "application/epub+zip" },
    .{ .kind = .pdf, .ext = ".pdf", .mime = "application/pdf" },
    .{ .kind = .djvu, .ext = ".djvu", .mime = "image/vnd.djvu" },
};

fn allowed(mask: u8, kind: import.Kind) bool {
    return mask & (@as(u8, 1) << @intFromEnum(kind)) != 0;
}

/// Отказ: формат этому участнику не разрешён в панели.
fn formatDenied(c: *Ctx, kind: import.Kind) void {
    c.status = 403;
    c.no_cache = true;
    uploadPage(c, std.mem.concat(c.a, u8, &.{ T("Формат "), @tagName(kind), T(" вам выкладывать не разрешено: так настроено администратором.") }) catch "");
}

pub fn uploadPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    w.s("<h2>Выложить книгу</h2>");
    c.msgBox(msg);
    w.byte('\n');
    if (!c.featureOpen(.upload)) {
        w.s("<p>Публичное выкладывание книг отключено администратором.</p>");
    } else if (h.gate(c, dbm.rights.upload, .upload)) {
        // какие форматы можно этому участнику, решено в панели
        const ok = c.formats();
        if (ok == 0) {
            w.s("<p class=\"box\">Администратор не разрешил вам ни одного формата загрузки.</p>");
        } else {
            w.raw("<form action=\"/b/upload\" method=\"post\" enctype=\"multipart/form-data\" class=\"box\">");
            c.post();
            voice.voiceField(c);
            w.s("\n<table><tr><td>Название</td><td><input name=\"title\" size=\"40\"></td></tr>\n<tr><td>Аннотация</td><td><textarea name=\"annotation\" rows=\"2\" cols=\"50\"></textarea></td></tr>\n");
            source.row(c, "");
            if (allowed(ok, .txt)) w.s("<tr><td valign=\"top\">Текст</td><td><textarea name=\"text\" rows=\"10\" cols=\"50\"></textarea><br><span class=\"muted\">Главы начинайте строкой «## Название главы». Без заголовков — одна глава.</span></td></tr>\n<tr><td>или файл") else w.s("<tr><td>Файл");
            var first = true;
            for (upload_kinds) |k| if (allowed(ok, k.kind)) {
                w.raw(if (first) " " else ", ");
                first = false;
                w.raw(k.ext);
            };
            w.raw("</td><td><input type=\"file\" name=\"file\" accept=\"");
            first = true;
            for (upload_kinds) |k| if (allowed(ok, k.kind)) {
                if (!first) w.byte(',');
                first = false;
                w.raw(k.ext);
                if (k.kind == .djvu) w.raw(",.djv");
            };
            for (upload_kinds) |k| if (allowed(ok, k.kind) and k.mime.len > 0) {
                w.byte(',');
                w.raw(k.mime);
            };
            w.s("\"><br><span class=\"muted\">Название и главы берутся из файла; название можно задать своё.");
            const pdf = allowed(ok, .pdf);
            const djvu = allowed(ok, .djvu);
            if (pdf and djvu) w.s(" PDF и DjVu — только с текстом внутри: сканы не распознаются.") else if (pdf) w.s(" PDF — только с текстом внутри: сканы не распознаются.") else if (djvu) w.s(" DjVu — только с текстом внутри: сканы не распознаются.");
            w.s("</span></td></tr>\n<tr><td></td><td><label><input type=\"checkbox\" name=\"embed\" value=\"1\" checked> разрешить встраивание (iframe)</label></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"Опубликовать\"></td></tr></table></form>");
        }
    }
    c.page(.{ .title = T("Выложить книгу"), .sec = "/b", .crumbs = &.{ .{ .text = T("Книги"), .href = "/b" }, .{ .text = T("Выложить") } } });
}

/// Свободный номер новой книги.
pub fn newBookId(c: *Ctx) i32 {
    while (true) {
        // 0, 1 и 2 — номера встроенных книг, выложенным они не достаются никогда
        const id = c.db.nextId("book", 3, 1);
        if (id > 2 and c.db.s.book(id) == null) return id;
    }
}

fn oneLine(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, s) catch return "";
    for (out) |*ch| if (ch.* == '\n') {
        ch.* = ' ';
    };
    return out;
}

/// Сохраняет книгу сайта файлом `books/N.txt` (UTF-8, шапка `#clipper-book`)
/// и просит пересобрать снимок. `text` — в windows-1251, главы через «## ».
pub fn saveTextBook(c: *Ctx, id: i32, title: []const u8, author: i32, annotation: []const u8, drafts_csv: []const u8, text: []const u8, embed: bool) !void {
    var cp_buf = std.ArrayList(u8).init(c.a);
    try cp_buf.writer().print("#clipper-book\ntitle: {s}\nauthor: {d}\nuploader: {d}\nyear: {s}\nannotation: {s}\n", .{
        oneLine(c.a, title), author, c.me.?.user, c.today()[0..4], if (annotation.len > 0) oneLine(c.a, annotation) else T("—"),
    });
    if (drafts_csv.len > 0) try cp_buf.writer().print("drafts: {s}\n", .{drafts_csv});
    try cp_buf.append('\n');
    try cp_buf.appendSlice(text);
    try cp_buf.append('\n');
    const utf8 = try cp.toUtf8Alloc(c.a, cp_buf.items);
    const name = try std.fmt.allocPrint(c.a, "{d}.txt", .{id});
    var dir = try c.app.root.makeOpenPath(library.books_dir, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = name, .data = utf8 });
    var nb: [16]u8 = undefined;
    c.db.l.put(L.key(c.a, "m", .{name}), std.fmt.bufPrint(&nb, "{d}", .{id}) catch unreachable);
    c.db.putBookStat(id, .{ .embed = embed }, false);
    c.app.rebuild_wanted = true;
}

pub fn uploadPost(c: *Ctx) void {
    if (!c.can(dbm.rights.upload, .upload)) return c.denied(T("Нет права выкладывать книги или функция отключена."));
    var title = c.form.get("title");
    var text = c.form.get("text");
    const embed = c.form.on("embed");
    const ok = c.formats();
    var from_file = false;
    if (c.form.file("file")) |f| {
        if (f.value.len > 0) {
            from_file = true;
            const kind = import.detect(f.filename orelse "", f.value);
            if (!allowed(ok, kind)) return formatDenied(c, kind);
            if (kind == .pdf or kind == .djvu) return uploadConverted(c, kind, f.value, f.filename orelse "", title, embed);
            if (kind == .fb2 or kind == .epub) {
                // FB2 и EPUB кладутся как есть, если разбираются: картинки из них
                // достаёт сборка снимка (BACKLOG_RU.md §17)
                var parse_arena = std.heap.ArenaAllocator.init(c.app.gpa);
                defer parse_arena.deinit();
                var budget = import.Budget{ .left = import.budget_bytes };
                const parsed = import.parse(parse_arena.allocator(), kind, f.value, &budget) catch |err| return fail400(c, import.reason(err));
                if (parsed.chapters.len == 0) return fail400(c, T("В файле нет текста."));
                const id = newBookId(c);
                const name = std.fmt.allocPrint(c.a, "{d}{s}", .{ id, if (kind == .fb2) ".fb2" else ".epub" }) catch return c.fail(500, "");
                var dir = c.app.root.makeOpenPath(library.books_dir, .{}) catch return c.fail(500, T("Папка книг недоступна."));
                defer dir.close();
                dir.writeFile(.{ .sub_path = name, .data = f.value }) catch return c.fail(500, T("Файл не сохранён."));
                var nb: [16]u8 = undefined;
                c.db.l.put(L.key(c.a, "m", .{name}), std.fmt.bufPrint(&nb, "{d}", .{id}) catch unreachable);
                c.db.l.put(L.key(c.a, "o", .{id}), std.fmt.bufPrint(&nb, "{d}", .{c.me.?.user}) catch unreachable);
                c.db.putBookStat(id, .{ .embed = embed }, false);
                c.app.rebuild_wanted = true;
                afterUpload(c, id);
                return c.redirect("/b/{d}", .{id});
            }
            text = std.mem.trim(u8, @import("../http.zig").cleanText(c.a, f.value) catch "", " \n");
        }
    }
    if (!from_file and text.len > 0 and !allowed(ok, .txt)) return formatDenied(c, .txt);
    if (title.len == 0 or text.len == 0) return fail400(c, T("Нужны название и текст."));
    if (title.len > 300) title = title[0..300];
    if ((fb2.splitChapters(c.a, text) catch return fail400(c, T("Слишком много глав."))).len == 0) return fail400(c, T("Нужны название и текст."));
    const id = newBookId(c);
    saveTextBook(c, id, title, c.me.?.user, c.form.get("annotation"), "", text, embed) catch return c.fail(500, T("Книга не сохранена."));
    afterUpload(c, id);
    c.redirect("/b/{d}", .{id});
}

/// EPUB и PDF: файл разбирается сразу, в папку книг ложится канонический
/// текст. Разбор идёт в своей памяти: буфер запроса для него мал.
fn uploadConverted(c: *Ctx, kind: import.Kind, bytes: []const u8, filename: []const u8, form_title: []const u8, embed: bool) void {
    var arena = std.heap.ArenaAllocator.init(c.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var budget = import.Budget{ .left = import.budget_bytes };
    var parsed = import.parse(a, kind, bytes, &budget) catch |err| return fail400(c, import.reason(err));
    if (form_title.len > 0) parsed.title = form_title[0..@min(form_title.len, 300)];
    if (parsed.title.len == 0) {
        // названия нет ни в форме, ни в файле: имя файла без расширения
        const base = std.fs.path.basename(filename);
        const stem = base[0 .. base.len - std.fs.path.extension(base).len];
        parsed.title = if (cp.looksUtf8(stem)) (cp.encodeAlloc(a, stem) catch stem) else stem;
        if (parsed.title.len == 0) parsed.title = T("Без названия");
    }
    const note = c.form.get("annotation");
    if (note.len > 0) parsed.annotation = note;
    const file = import.canonical(a, parsed, c.me.?.user) catch return c.fail(500, T("Книга не сохранена."));
    const id = newBookId(c);
    const name = std.fmt.allocPrint(c.a, "{d}.txt", .{id}) catch return c.fail(500, "");
    var dir = c.app.root.makeOpenPath(library.books_dir, .{}) catch return c.fail(500, T("Папка книг недоступна."));
    defer dir.close();
    dir.writeFile(.{ .sub_path = name, .data = file }) catch return c.fail(500, T("Файл не сохранён."));
    var nb: [16]u8 = undefined;
    c.db.l.put(L.key(c.a, "m", .{name}), std.fmt.bufPrint(&nb, "{d}", .{id}) catch unreachable);
    c.db.putBookStat(id, .{ .embed = embed }, false);
    c.app.rebuild_wanted = true;
    afterUpload(c, id);
    c.redirect("/b/{d}", .{id});
}

/// Выложенная книга: источник из формы и привязка записи, если книгу выкладывали от неё.
fn afterUpload(c: *Ctx, id: i32) void {
    source.save(c, 'b', id);
    voice.attachNew(c, 'b', id);
}

/// Кто правит источник книги: кто выложил, автор и привязанные к нему участники, сотрудник, /u/0.
pub fn canEditBook(c: *const Ctx, b: snapshot.Book) bool {
    const me = c.me orelse return false;
    if (c.isModerator()) return true;
    if (b.uploader != 0 and me.user == b.uploader) return true;
    if (me.user != 0 and me.user == b.author) return true;
    for (c.db.authorsOf(me.user)) |p| if (p == b.author) return true;
    return false;
}

/// POST /b/N/source: источник книги.
pub fn sourcePost(c: *Ctx, id: i32) void {
    const b = c.db.s.book(id) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEditBook(c, b.*)) return c.denied(T("Источник правят выложивший книгу, её автор, сотрудник и /u/0."));
    source.save(c, 'b', id);
    c.redirect("/b/{d}", .{id});
}

fn fail400(c: *Ctx, msg: []const u8) void {
    c.status = 400;
    c.no_cache = true;
    uploadPage(c, msg);
}
