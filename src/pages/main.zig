//! Главная, схема адресов, поиск, стихи (/p), участники (/u).

const std = @import("std");
const poems = @import("poems.zig");
const chordpro = @import("../chordpro.zig");
const cp = @import("../cp1251.zig");
const http = @import("../http.zig");
const dbm = @import("../db.zig");
const layout = @import("../layout.zig");
const Ctx = @import("../app.zig").Ctx;
const app_sections = @import("../app.zig").sections;
const h = @import("h.zig");
const marks = @import("marks.zig");
const library = @import("../library.zig");
const home_mod = @import("home.zig");
const forum_pages = @import("forum.zig");
const books_pages = @import("books.zig");

const T = cp.text;

pub fn home(c: *Ctx) void {
    const set = home_mod.listed(c);
    // гостю открыт ровно один раздел (-G) — главная для него сразу этот раздел
    if (c.me == null and c.app.cfg.sec.guest_set and @popCount(set) == 1) {
        const only: u3 = @intCast(@ctz(set));
        return switch (@as(app_sections.Sec, @enumFromInt(only))) {
            .p => pieceIndex(c),
            .b => books_pages.index(c),
            .d => @import("drafts.zig").index(c, ""),
            .f => forum_pages.index(c),
            .q => marks.personIndex(c, ""),
            .v => @import("voice.zig").index(c),
        };
    }
    // гостю открыты только записи (-Gv)
    if (c.me == null and c.app.cfg.sec.guest_set and set == 0 and c.secListed(.v)) return @import("voice.zig").index(c);
    if (home_mod.render(c)) return;
    const w = &c.w;
    const s = c.db.s;
    w.f("\n<h2>Добро пожаловать в {h}</h2>", .{c.app.name});
    w.raw("\n<p>");
    home_mod.describe(w, home_mod.listed(c));
    w.s("</p>\n<table width=\"100%\" cellpadding=\"4\"><tr>\n");
    var shown: usize = 0;
    for (layout.sections) |sec| {
        if (!layout.sectionOn(c, sec.href)) continue;
        const i = shown;
        shown += 1;
        if (i % 3 == 0 and i > 0) w.raw("</tr><tr>");
        w.f("<td width=\"33%\" valign=\"top\" class=\"box\"><a href=\"{U}{s}{E}\"><b>{s}</b></a><br><span class=\"muted\">{s}</span></td>", .{ sec.href, sec.title, sec.hint });
    }
    w.s("\n</tr></table>\n<h3>Новое в библиотеке</h3>\n");
    var t = h.Table.begin(c, &.{ "Что", "Автор", "Адрес" });
    const nb = if (c.secListed(.b)) s.books.len else 0;
    var k: usize = nb -| 2;
    while (k < nb) : (k += 1) {
        const b = s.bookAt(k);
        t.row();
        w.f("<td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ b.id, s.str(b.title) });
        c.bookAuthor(b.id, b.author);
        w.f("</td><td>/b/{d}</td></tr>", .{b.id});
    }
    var pk: usize = if (c.secListed(.p)) s.pieces.len -| 3 else s.pieces.len;
    while (pk < s.pieces.len) : (pk += 1) {
        const p = s.pieceAt(pk);
        t.row();
        w.f("<td><a href=\"{U}/p/{d}{E}\">{h}</a> <span class=\"muted\">{h}</span></td><td>", .{ p.id, s.str(p.title), s.str(p.genre) });
        c.aLink(p.author);
        w.f("</td><td>/p/{d}</td></tr>", .{p.id});
    }
    if (c.secListed(.d)) {
        const pos = c.db.drafts(false);
        const neg = c.db.drafts(true);
        const all = std.mem.concat(c.a, dbm.Draft, &.{ pos, neg }) catch pos;
        // последние по времени создания
        std.mem.sort(dbm.Draft, all, {}, struct {
            fn lt(_: void, x: dbm.Draft, y: dbm.Draft) bool {
                return x.seq < y.seq;
            }
        }.lt);
        for (all[all.len -| 2..]) |d| {
            t.row();
            w.f("<td><a href=\"{U}/d/{d}{E}\">{h}</a></td><td>", .{ d.id, d.title });
            c.aLink(d.author);
            w.f("</td><td>/d/{d}</td></tr>", .{d.id});
        }
    }
    t.end();
    w.s("\n<div class=\"box\">");
    if (library.has_book0 and c.secListed(.b)) w.f("Впервые здесь? Прочтите <a href=\"{U}/b/0{E}\"><b>книгу о сайте</b></a> · ", .{});
    w.f("<a href=\"{U}/e{E}\">встраивание на свой сайт</a> · <a href=\"{U}/help{E}\">схема адресов</a></div>\n", .{});
    if (c.secListed(.q)) w.s("<h3>Цитата дня</h3>\n");
    const qs = if (c.secListed(.q)) c.db.quotes() else &[_]dbm.Quote{};
    if (qs.len > 0) {
        const q = qs[http.civil(c.app.now).day % qs.len];
        w.f("<blockquote>{h}<br><span class=\"muted\">— ", .{q.text});
        c.aLink(q.person);
        w.raw("</span></blockquote>\n");
    }
    c.page(.{ .title = T("Главная") });
}

pub fn help(c: *Ctx) void {
    const w = &c.w;
    w.s("<h2>Схема адресов</h2><table class=\"list\"><tr><th>Адрес</th><th>Значение</th></tr>");
    if (c.secListed(.p)) w.f("<tr><td><code>/p/{piece}</code></td><td>piece&gt;0 — стихи, верлибры, бардовская песня; piece&lt;0 — песня с нотами. Пример: <a href='{U}/p/2{E}'>/p/2</a>, <a href='{U}/p/-1{E}'>/p/-1</a></td></tr>", .{});
    if (c.secListed(.b)) w.f("<tr><td><code>/b/{book}</code></td><td>book&gt;0 — книга, book&lt;0 — серия книг. <a href='{U}/b/2{E}'>/b/2</a>, <a href='{U}/b/-1{E}'>/b/-1</a></td></tr>", .{});
    if (c.secListed(.b)) w.f("<tr><td><code>/q/{book&gt;0}</code></td><td>сразу режим чтения книги, ?ch=N — глава. <a href='{U}/q/2{E}'>/q/2</a></td></tr>", .{});
    if (c.secListed(.q)) w.f("<tr><td><code>/c/{person}</code></td><td>цитаты: person&gt;0 — автор, &lt;0 — персонаж (автор → книги, заводится заранее). Цитаты делаются только из книги: выделить текст, правая кнопка мыши. Фильтр: op, ed, sz. <a href='{U}/c{E}'>/c</a></td></tr>", .{});
    if (c.secListed(.b)) w.s("<tr><td><code>/bookmarks</code></td><td>мои закладки с примечаниями (личные)</td></tr>");
    if (@import("voice.zig").enabled and c.secListed(.v)) w.f("<tr><td><code>/v/{rec}</code></td><td>rec&gt;0 — запись: аудиокнига (к книге /b) или исполнение стиха или песни (к /p); rec&lt;0 — чтец или исполнитель. Файл — /v/{rec}.mp3 (MP3 128 кбит/с). <a href='{U}/v{E}'>/v</a></td></tr>", .{});
    if (c.secListed(.d)) w.f("<tr><td><code>/d/{draft}</code></td><td>draft&gt;0 — черновик/фрагмент (можно перенести в /p или объединить в /b — после этого только чтение); draft&lt;0 — статья. <a href='{U}/d/1{E}'>/d/1</a>, <a href='{U}/d/-1{E}'>/d/-1</a></td></tr>", .{});
    if (c.secListed(.f)) w.f("<tr><td><code>/f/{forum:uint}</code></td><td>обычный форум. <a href='{U}/f/1{E}'>/f/1</a></td></tr>", .{});
    if (c.secListed(.f)) w.f("<tr><td><code>/f/{board:str}</code></td><td>анонимная имиджборда с автоудалением тредов. <a href='{U}/f/b{E}'>/f/b</a></td></tr>", .{});
    w.f("<tr><td><code>/u/{user}</code></td><td>user&gt;0 — пользователь, &lt;0 — автор (Unveiler / Upbuilder). <a href='{U}/u/1001{E}'>/u/1001</a>, <a href='{U}/u/-101{E}'>/u/-101</a></td></tr>", .{});
    if (library.has_book0 and c.secListed(.b)) w.f("<tr><td><code>/b/0</code></td><td>книга о самом сайте. <a href='{U}/b/0{E}'>/b/0</a></td></tr>", .{});
    w.f("<tr><td><code>/e</code></td><td>демонстрация встраивания (iframe) и бейджей. <a href='{U}/e{E}'>/e</a></td></tr>", .{});
    w.s("<tr><td><code>/signin /signup /logout /panel</code></td><td>вход, регистрация, сеансы и выход, панель (сайтом управляет /u/0)</td></tr>");
    w.s("<tr><td><code>?m=true|false</code></td><td>мобильная версия (по умолчанию — по User-Agent)</td></tr>");
    w.s("<tr><td><code>?t=тема</code></td><td>темы: flibusta (по умолчанию), samlib, proza, nepomn; суффиксы -light, -dark, -time; спец.: light, dark, time. Без суффикса — по настройкам устройства.</td></tr>");
    w.s("</table><p class=\"muted\">Параметры m и t сохраняются при переходах по всем ссылкам сайта.</p>");
    c.page(.{ .title = T("Схема адресов"), .crumbs = &.{.{ .text = T("Схема адресов") }} });
}

fn has(hay: []const u8, q: []const u8) bool {
    return cp.indexOfFold(hay, q) != null;
}

const max_hits = 500;

pub fn search(c: *Ctx) void {
    const w = &c.w;
    const s = c.db.s;
    const q = std.mem.trim(u8, c.q("q"), " ");
    w.s("<h2>Поиск</h2><form action=\"/s\">");
    c.hidden();
    w.f("<input name=\"q\" size=\"40\" value=\"{h}\"> <input type=\"submit\" value=\"Найти\"></form>", .{q});
    if (q.len > 0) {
        const count_at = w.n;
        w.raw("<p>" ++ " " ** 24 ++ "</p>"); // место под «Найдено: N»
        var t = h.Table.begin(c, &.{ "Тип", "Название", "Автор" });
        if (c.secListed(.p)) for (0..s.pieces.len) |pi| {
            const p = s.pieceAt(pi);
            if (t.rows >= max_hits) break;
            if (!has(s.str(p.title), q) and !has(s.str(p.text), q)) continue;
            t.row();
            w.f("<td>стих/песня</td><td><a href=\"{U}/p/{d}{E}\">{h}</a></td><td>", .{ p.id, s.str(p.title) });
            c.aLink(p.author);
            w.raw("</td></tr>");
        };
        // Текст книг просматривается целиком только в небольшой библиотеке.
        const deep = s.frames.len <= 2048;
        if (c.secListed(.b)) for (0..s.books.len) |k| {
            if (t.rows >= max_hits) break;
            const b = s.bookAt(k);
            var hit = has(s.str(b.title), q) or has(s.str(b.annotation), q);
            if (!hit and deep) {
                for (0..b.n_pages) |pi| {
                    const text = c.app.pageText(c.a, b, pi) catch continue;
                    hit = has(text, q);
                    c.a.free(text); // последнее выделение арены: место возвращается
                    if (hit) break;
                }
            }
            if (!hit) continue;
            t.row();
            w.f("<td>книга</td><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ b.id, s.str(b.title) });
            c.bookAuthor(b.id, b.author);
            w.raw("</td></tr>");
        };
        if (c.secListed(.b)) for (s.series) |x| {
            if (t.rows >= max_hits) break;
            if (!has(s.str(x.title), q)) continue;
            t.row();
            w.f("<td>серия</td><td><a href=\"{U}/b/{d}{E}\">{h}</a></td><td>", .{ x.id, s.str(x.title) });
            c.aLink(x.author);
            w.raw("</td></tr>");
        };
        if (c.secListed(.q)) for (c.db.quotes()) |x| {
            if (t.rows >= max_hits) break;
            if (!has(x.text, q)) continue;
            t.row();
            w.f("<td>цитата</td><td><a href=\"{U}/b/{d}/{d}#p{d}{E}\">{h}…</a></td><td>", .{ x.book, x.ch, x.para, x.text[0..@min(x.text.len, 80)] });
            c.aLink(x.person);
            w.raw("</td></tr>");
        };
        if (c.secListed(.q)) for (s.persons) |p| {
            if (t.rows >= max_hits) break;
            if (!has(s.str(p.name), q)) continue;
            t.row();
            w.f("<td>человек</td><td><a href=\"{U}/c/{d}{E}\">{h}</a></td><td></td></tr>", .{ p.id, s.str(p.name) });
        };
        if (c.secListed(.q)) for (c.db.characters()) |p| {
            if (t.rows >= max_hits) break;
            if (!has(p.name, q)) continue;
            t.row();
            w.f("<td>персонаж</td><td><a href=\"{U}/c/{d}{E}\">{h}</a></td><td></td></tr>", .{ p.id, p.name });
        };
        if (c.secListed(.d)) inline for (.{ false, true }) |neg| {
            for (c.db.drafts(neg)) |d| {
                if (t.rows >= max_hits) break;
                if (!has(d.title, q) and !has(d.text, q)) continue;
                t.row();
                w.f("<td>{s}</td><td><a href=\"{U}/d/{d}{E}\">{h}</a></td><td>", .{ if (neg) T("статья") else T("черновик"), d.id, d.title });
                c.aLink(d.author);
                w.raw("</td></tr>");
            }
        };
        inline for (.{ false, true }) |neg| {
            for (c.db.users(neg)) |u| {
                if (t.rows >= max_hits) break;
                if (!has(u.nick, q)) continue;
                t.row();
                w.f("<td>участник</td><td><a href=\"{U}/u/{d}{E}\">{h}</a></td><td></td></tr>", .{ u.id, u.nick });
            }
        }
        var nb: [40]u8 = undefined;
        const label = std.fmt.bufPrint(&nb, "{s}{d}{s}", .{ T("Найдено: "), t.rows, if (t.rows >= max_hits) "+" else "" }) catch "";
        @memcpy(w.buf[count_at + 3 ..][0..label.len], label);
        t.end();
    }
    c.page(.{ .title = T("Поиск"), .crumbs = &.{.{ .text = T("Поиск") }} });
}

// ───────────── /p ─────────────

pub fn pieceIndex(c: *Ctx) void {
    const w = &c.w;
    const s = c.db.s;
    const genre = c.q("g"); // рубрика (?g=жанр); пусто — все
    if (c.can(dbm.rights.write, .poems) and c.featureOpen(.poems) and c.secWritable(.p)) w.f("<p><a href=\"{U}/p/new{E}\">Выложить стих или песню</a> — от своего имени или от имени любого автора</p>\n", .{});
    if (genre.len > 0) w.f("<p class=\"muted\">Рубрика: <b>{h}</b> · <a href=\"{U}/p{E}\">все</a></p>", .{genre});
    inline for (.{ false, true }) |neg| {
        if (neg) w.s("<h2>Песни с нотами</h2>") else w.s("<h2>Стихи, верлибры, бардовская песня</h2>");
        var t = h.Table.begin(c, &.{ "№", "Название", "Жанр", "Автор", "Год" });
        for (0..s.pieces.len) |pi| {
            const p = s.pieceAt(pi);
            if ((p.id < 0) != neg) continue;
            if (genre.len > 0 and !cp.eqlFold(s.str(p.genre), genre)) continue;
            t.row();
            w.raw("<td>");
            c.sign(p.id);
            w.f("</td><td><a href=\"{U}/p/{d}{E}\">{h}</a></td><td>{h}</td><td>", .{ p.id, s.str(p.title), s.str(p.genre) });
            c.aLink(p.author);
            w.f("</td><td>{h}</td></tr>", .{s.str(p.year)});
        }
        t.end();
    }
    c.page(.{ .title = T("Стихи и песни"), .sec = "/p", .crumbs = &.{.{ .text = T("Стихи") }} });
}

pub fn piece(c: *Ctx, id: i32) void {
    const w = &c.w;
    const s = c.db.s;
    const p = c.db.piece(id) orelse return c.notFound();
    const song = id < 0;
    w.f("<h2>{h}</h2>\n<div class=\"muted\">", .{p.title});
    c.aLink(p.author);
    w.f(" · {h}", .{p.genre});
    if (p.year.len > 0) w.f(" · {h}", .{p.year});
    w.f(" · <code>/p/{d}</code></div>\n", .{id});
    @import("source.zig").show(c, 'p', id);
    if (p.uploader != 0 and p.uploader != p.author) {
        w.s("<div class=\"muted\">Выложил: ");
        c.aLink(p.uploader);
        w.raw("</div>\n");
    }
    if (p.chordpro) {
        chordpro.renderIds(w, p.text, true);
        if (p.notes.len > 0) w.f("<h3>Ноты (ABC-нотация)</h3><pre class=\"abc\">{h}</pre>", .{p.notes});
    } else {
        h.parasIds(c, p.text, "div", "verse");
        w.byte('\n');
        if (song) w.f("<h3>Аккорды</h3><pre class=\"abc\">{h}</pre><h3>Ноты (ABC-нотация)</h3><pre class=\"abc\">{h}</pre>", .{ p.chords, p.notes });
    }
    if (poems.canEdit(c, p.author, p.uploader)) w.f("<p><a href=\"{U}/p/{d}/edit{E}\">Править или удалить</a></p>\n", .{id});
    @import("voice.zig").forPiece(c, id);
    marks.textMarkUi(c, std.fmt.allocPrint(c.a, "/p/{d}/mark", .{id}) catch "", p.author, @intCast(h.paraList(c.a, if (p.chordpro) chordpro.lyrics(c.a, p.text) else p.text).len));
    var others: usize = 0;
    var prev: ?i32 = null;
    var next: ?i32 = null;
    for (0..s.pieces.len) |i| {
        const x = s.pieceAt(i);
        if (x.id == id) {
            if (i > 0) prev = s.pieceAt(i - 1).id;
            if (i + 1 < s.pieces.len) next = s.pieceAt(i + 1).id;
            continue;
        }
        if (x.author != p.author) continue;
        if (others == 0) w.s("\n<h3>Ещё у автора</h3>") else w.s(" · ");
        others += 1;
        w.f("<a href=\"{U}/p/{d}{E}\">{h}</a>", .{ x.id, s.str(x.title) });
    }
    w.raw("<p class=\"pager\">");
    if (prev) |x| w.f("<a href=\"{U}/p/{d}{E}\">&laquo; предыдущее</a>", .{x});
    w.byte(' ');
    if (next) |x| w.f("<a href=\"{U}/p/{d}{E}\">следующее &raquo;</a>", .{x});
    w.raw("</p>");
    c.page(.{ .title = p.title, .sec = "/p", .crumbs = &.{ .{ .text = T("Стихи"), .href = "/p" }, .{ .text = if (song) T("Песни с нотами") else p.genre, .href = "/p" }, .{ .text = p.title } } });
}

// ───────────── /u ─────────────

pub fn userIndex(c: *Ctx) void {
    const w = &c.w;
    inline for (.{ true, false }) |neg| {
        if (neg) w.s("<h2>Авторы (Unveiler / Upbuilder)</h2>") else w.s("<h2>Пользователи</h2>");
        var t = h.Table.begin(c, &.{ "№", "Ник", "С нами с", "О себе" });
        for (c.db.users(neg)) |u| {
            if (u.id == 0) continue;
            t.row();
            w.raw("<td>");
            c.sign(u.id);
            w.f("</td><td><a href=\"{U}/u/{d}{E}\">{h}</a></td><td>{h}</td><td>{h}</td></tr>", .{ u.id, u.nick, u.joined, u.about });
        }
        t.end();
    }
    c.page(.{ .title = T("Участники"), .sec = "/u", .crumbs = &.{.{ .text = T("Авторы") }} });
}

const Sec = struct {
    c: *Ctx,
    n: usize = 0,
    fn item(x: *Sec, comptime title: []const u8) void {
        if (x.n == 0) {
            x.c.w.raw("<h3>");
            x.c.w.s(title);
            x.c.w.raw("</h3><ul>");
        }
        x.n += 1;
        x.c.w.raw("<li>");
    }
    fn end(x: *Sec) void {
        if (x.n > 0) x.c.w.raw("</ul>");
        x.c.w.byte('\n');
        x.n = 0;
    }
};

pub fn user(c: *Ctx, id: i32) void {
    const w = &c.w;
    const s = c.db.s;
    const u = c.db.user(id) orelse return c.notFound();
    w.f("<h2>{h}</h2><div class=\"muted\">{s} · с {h} · <code>/u/{d}</code></div><p>{h}</p>\n", .{ u.nick, if (id < 0) T("автор") else T("пользователь"), u.joined, id, u.about });
    poems.userAuthors(c, id);
    @import("voice.zig").userReaders(c, id);
    @import("profile.zig").show(c, id, if (@import("profile.zig").canEditUser(c, id)) (std.fmt.allocPrint(c.a, "/u/{d}/edit", .{id}) catch null) else null);
    var sec = Sec{ .c = c };
    if (c.secListed(.p)) for (0..s.pieces.len) |pi| {
        const p = s.pieceAt(pi);
        if (p.author != id) continue;
        sec.item("Стихи и песни");
        w.f("<a href=\"{U}/p/{d}{E}\">{h}</a> <span class=\"muted\">{h}</span></li>", .{ p.id, s.str(p.title), s.str(p.genre) });
    };
    sec.end();
    if (c.secListed(.b)) for (s.series) |x| if (x.author == id) {
        sec.item("Серии");
        w.f("<a href=\"{U}/b/{d}{E}\">{h}</a></li>", .{ x.id, s.str(x.title) });
    };
    sec.end();
    if (c.secListed(.b)) for (0..s.books.len) |k| {
        const b = s.bookAt(k);
        if (b.author != id) continue;
        sec.item("Книги");
        w.f("<a href=\"{U}/b/{d}{E}\">{h}</a></li>", .{ b.id, s.str(b.title) });
    };
    sec.end();
    if (c.secListed(.d)) for (c.db.drafts(false)) |d| if (d.author == id) {
        sec.item("Черновики");
        w.f("<a href=\"{U}/d/{d}{E}\">{h}</a></li>", .{ d.id, d.title });
    };
    sec.end();
    if (c.secListed(.d)) for (c.db.drafts(true)) |d| if (d.author == id) {
        sec.item("Статьи");
        w.f("<a href=\"{U}/d/{d}{E}\">{h}</a></li>", .{ d.id, d.title });
    };
    sec.end();
    if (c.secListed(.f)) for (c.db.allPosts()) |p| if (p.author == id) {
        const f = c.db.forum(p.forum) orelse continue;
        const t = c.db.topic(p.forum, p.topic) orelse continue;
        sec.item("Сообщения на форуме");
        w.f("<a href=\"{U}/f/{d}?topic={d}{E}\">{h}</a> <span class=\"muted\">({h})</span></li>", .{ f.id, t.id, t.title, f.title });
    };
    sec.end();
    c.page(.{ .title = u.nick, .sec = "/u", .crumbs = &.{ .{ .text = T("Авторы"), .href = "/u" }, .{ .text = if (id < 0) T("Авторы") else T("Пользователи"), .href = "/u" }, .{ .text = u.nick } } });
}
