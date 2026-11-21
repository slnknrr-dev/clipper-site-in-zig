//! Цитаты и закладки делаются только со страницы чтения книги: выделить
//! текст → правая кнопка мыши → своё контекстное меню (`oncontextmenu`,
//! IE5+/NN6+) → «Закладка с примечанием» (личная) или «Цитата» (публичная,
//! приписывается автору книги или его персонажу). Без JavaScript то же
//! делается формой под текстом. Здесь же — /bookmarks и раздел /c.

const std = @import("std");
const cp = @import("../cp1251.zig");
const dbm = @import("../db.zig");
const snapshot = @import("../snapshot.zig");
const W = @import("../out.zig").W;
const Ctx = @import("../app.zig").Ctx;
const h = @import("h.zig");

const T = cp.text;

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r' or ch == 0xA0;
}

/// Ищет `text` в абзаце без учёта различий в пробелах; [начало, конец) в абзаце.
pub fn findIn(para: []const u8, text: []const u8) ?[2]usize {
    const needle = std.mem.trim(u8, text, " \n\t\r\xA0");
    if (needle.len == 0) return null;
    var start: usize = 0;
    while (start < para.len) : (start += 1) {
        var i = start;
        var k: usize = 0;
        while (k < needle.len) {
            if (isSpace(needle[k])) {
                while (k < needle.len and isSpace(needle[k])) k += 1;
                if (i >= para.len or !isSpace(para[i])) break;
                while (i < para.len and isSpace(para[i])) i += 1;
                continue;
            }
            if (i >= para.len or para[i] != needle[k]) break;
            i += 1;
            k += 1;
        } else return .{ start, i };
    }
    return null;
}

/// Где живёт тот, кому приписана цитата: люди и персонажи — на /c, авторы сайта — на /u.
fn whoPrefix(c: *Ctx, id: i32) []const u8 {
    return if (c.db.person(id) != null) "/c/" else if (c.db.isUser(id)) "/u/" else "/c/";
}

const Target = struct { id: i32, name: []const u8, character: bool };

/// Кому можно приписать цитату из книги: автору, затем его персонажам для этой книги.
fn quoteTargets(c: *Ctx, b: *const snapshot.Book) []Target {
    var list = std.ArrayList(Target).init(c.a);
    list.append(.{ .id = b.author, .name = c.db.name(b.author), .character = false }) catch {};
    for (c.db.characters()) |p| {
        if (p.author == b.author and dbm.Db.charInBook(p.books, b.id)) list.append(.{ .id = p.id, .name = p.name, .character = true }) catch break;
    }
    return list.items;
}

fn peopleOptions(c: *Ctx, targets: []const Target) void {
    for (targets) |t| c.w.f("<option value=\"{d}\">{h} ({s})</option>", .{ t.id, t.name, if (t.character) T("персонаж") else T("автор") });
}

// ───────────── страница чтения ─────────────

const Range = struct { s: usize, e: usize, quote: bool, id: i32, person: i32, note: []const u8 };

pub fn readingText(c: *Ctx, b: *const snapshot.Book, n: u32, text: []const u8) void {
    const w = &c.w;
    const quotes: []dbm.Quote = if (c.secListed(.q)) c.db.quotes() else &.{};
    const bms: []dbm.Bookmark = if (c.me != null and c.secListed(.b)) c.db.bookmarks(c.me.?.user) else &.{};
    w.raw("<div class=\"text\" id=\"booktext\" style=\"margin:0 auto\">");
    var it = std.mem.splitSequence(u8, text, "\n\n");
    var i: u32 = 0;
    while (it.next()) |p| : (i += 1) {
        if (@import("../fb2.zig").imageOf(p)) |k| {
            if (i > 0) w.byte('\n');
            w.f("<div id=\"p{d}\"><a name=\"p{d}\"></a>", .{ i, i });
            if (c.db.s.image(k)) |im| h.figure(c, im, @import("../img/image.zig").box_w, @import("../img/image.zig").box_h);
            w.raw("</div>");
            continue;
        }
        // отметки абзаца — непересекающиеся отрезки, кто первый, тот и занял
        var rs: [24]Range = undefined;
        var rn: usize = 0;
        for (quotes) |q| {
            if (q.src != 'b' or q.book != b.id or q.ch != n or q.para != i or rn == rs.len) continue;
            const r = findIn(p, q.text) orelse continue;
            var clash = false;
            for (rs[0..rn]) |x| clash = clash or (r[0] < x.e and x.s < r[1]);
            if (clash) continue;
            rs[rn] = .{ .s = r[0], .e = r[1], .quote = true, .id = q.id, .person = q.person, .note = "" };
            rn += 1;
        }
        for (bms) |m| {
            if (m.book != b.id or m.ch != n or m.para != i or rn == rs.len) continue;
            const r = findIn(p, m.text) orelse continue;
            var clash = false;
            for (rs[0..rn]) |x| clash = clash or (r[0] < x.e and x.s < r[1]);
            if (clash) continue;
            rs[rn] = .{ .s = r[0], .e = r[1], .quote = false, .id = m.id, .person = 0, .note = m.note };
            rn += 1;
        }
        std.mem.sort(Range, rs[0..rn], {}, struct {
            fn lt(_: void, x: Range, y: Range) bool {
                return x.s < y.s;
            }
        }.lt);
        if (i > 0) w.byte('\n');
        w.f("<p id=\"p{d}\"><a name=\"p{d}\"></a>", .{ i, i });
        var at: usize = 0;
        for (rs[0..rn]) |r| {
            w.escBrLinks(p[at..r.s]);
            if (r.quote) {
                w.f("<span class=\"mq\" title=\"Цитата: {h}\">{b}</span><sup><a href=\"{U}{s}{d}{E}#q{d}\" title=\"цитата №{d}\">ц</a></sup>", .{ c.db.name(r.person), p[r.s..r.e], whoPrefix(c, r.person), r.person, r.id, r.id });
            } else {
                w.f("<span class=\"mb\" title=\"Закладка: {h}\">{b}</span><sup><a href=\"{U}/bookmarks{E}#m{d}\" title=\"{h}\">з</a></sup>", .{ r.note, p[r.s..r.e], r.id, r.note });
            }
            at = r.e;
        }
        w.escBrLinks(p[at..]);
        w.raw("</p>");
    }
    w.raw("</div>");
    // отметки — закладки (раздел книг) и цитаты; у скрытых книг цитатника их нет
    if (c.secListed(.b)) markUi(c, b, n, i);
}

fn popup(c: *Ctx, action: []const u8, comptime kind: []const u8, comptime title: []const u8, targets: []const Target) void {
    const w = &c.w;
    w.f("<form id=\"cf-" ++ kind ++ "\" class=\"cform\" action=\"{s}\" method=\"post\" style=\"display:none\">", .{action});
    c.post();
    w.raw("\n<input type=\"hidden\" name=\"kind\" value=\"" ++ kind ++ "\"><input type=\"hidden\" name=\"para\" value=\"\"><input type=\"hidden\" name=\"text\" value=\"\">\n<b>");
    w.s(title);
    w.raw("</b><div class=\"cq\"></div>");
    if (comptime std.mem.eql(u8, kind, "bookmark")) {
        w.s("Примечание:<br><textarea name=\"note\" rows=\"3\" cols=\"34\"></textarea>");
    } else {
        w.s("Кому приписать:<br><select name=\"person\">");
        peopleOptions(c, targets);
        w.f("</select><br><span class=\"muted\">Персонажа нет в списке? <a href=\"{U}/c{E}\">Заведите его</a>.</span>", .{});
    }
    w.s("<br><input type=\"submit\" value=\"Сохранить\"> <input type=\"button\" value=\"Отмена\" onclick=\"cmHide()\"></form>");
}

/// Контекстное меню, его формы и запасная форма без JavaScript.
fn markUi(c: *Ctx, b: *const snapshot.Book, n: u32, count: u32) void {
    markUiAt(c, std.fmt.allocPrint(c.a, "/b/{d}/{d}/mark", .{ b.id, n }) catch "", quoteTargets(c, b), count, true);
}

/// Цитаты из стиха, песни или статьи: только цитаты (закладки — у книг).
pub fn textMarkUi(c: *Ctx, action: []const u8, author: i32, count: u32) void {
    if (!c.secListed(.q)) return;
    var t = [_]Target{.{ .id = author, .name = c.db.name(author), .character = false }};
    markUiAt(c, action, &t, count, false);
}

fn markUiAt(c: *Ctx, action: []const u8, targets: []const Target, count: u32, with_bookmarks: bool) void {
    const w = &c.w;
    const can_quote = c.can(dbm.rights.quote, .quotes);
    if (!with_bookmarks and !can_quote) return;
    if (c.me == null) {
        w.f("<div id=\"cmenu\" class=\"cmenu\" style=\"display:none\"><a href=\"{U}/signin?back={q}{E}\">Войдите</a>, чтобы ставить закладки и цитаты.</div>", .{c.req.path});
        w.f("<p class=\"muted hint\"><a href=\"{U}/signin?back={q}{E}\">Войдите</a>, чтобы ставить закладки и цитаты.</p>", .{c.req.path});
    } else {
        w.raw("<div id=\"cmenu\" class=\"cmenu\" style=\"display:none\">");
        if (with_bookmarks) w.s("<a href=\"#\" onclick=\"return cmOpen('bookmark')\">&#9998; Закладка с примечанием&hellip;</a>\n");
        if (can_quote) w.s("<a href=\"#\" onclick=\"return cmOpen('quote')\">&#8220; Цитата&hellip;</a>") else w.s("<span class=\"muted\">цитаты: нет права или отключены</span>");
        w.s("\n<span class=\"muted\">обычное меню — Shift + правая кнопка</span></div>");
        if (with_bookmarks) popup(c, action, "bookmark", "Закладка", targets);
        if (can_quote) popup(c, action, "quote", "Цитата для всех", targets);
        w.f("<div class=\"box nojs\"><b>Отметить фрагмент</b> <span class=\"muted\">(без мыши: выделите и нажмите правую кнопку, или заполните форму)</span>\n<form action=\"{s}\" method=\"post\">", .{action});
        c.post();
        w.s("Абзац <select name=\"para\">");
        var k: u32 = 0;
        while (k < count) : (k += 1) w.f("<option value=\"{d}\">{d}</option>", .{ k, k + 1 });
        w.s("</select>\nтекст <input name=\"text\" size=\"40\"><br>\n");
        if (with_bookmarks) w.s("<label><input type=\"radio\" name=\"kind\" value=\"bookmark\" checked> закладка</label>, примечание <input name=\"note\" size=\"24\">\n");
        if (can_quote) {
            if (with_bookmarks) w.raw("<br>");
            w.f("<label><input type=\"radio\" name=\"kind\" value=\"quote\"{s}> цитата</label>, кому <select name=\"person\">", .{if (with_bookmarks) "" else " checked"});
            peopleOptions(c, targets);
            w.raw("</select>");
        }
        w.s("\n<input type=\"submit\" value=\"Отметить\"></form></div>");
        if (c.mobile) w.s("<div class=\"markbar\"><input type=\"button\" value=\"&#9998; Отметить выделенное\" onclick=\"cmShow(null)\"></div>");
    }
    w.byte('\n');
    // Текст подсказки — отдельной строкой: так он идёт через каталог перевода.
    w.s("<script type=\"text/javascript\">var cmNoSel = \"Сначала выделите текст в книге.\";</script>\n");
    w.raw(comptime cp.lit(@embedFile("../tpl/marks.js")));
}

/// POST /b/N/K/mark
pub fn markPost(c: *Ctx, book_s: []const u8, page_s: []const u8) void {
    const id = std.fmt.parseInt(i32, book_s, 10) catch return c.notFound();
    for (book_s) |ch| if (ch < '0' or ch > '9') return c.notFound();
    const b = c.db.s.book(id) orelse return c.notFound();
    const n = std.fmt.parseInt(u32, page_s, 10) catch return c.notFound();
    if (n < 1 or n > b.n_pages) return c.notFound();
    const me = c.me orelse return c.redirect("/signin?back=/b/{d}/{d}", .{ id, n });
    const para_n = std.fmt.parseInt(u32, c.form.get("para"), 10) catch return c.fail(400, T("Нет такого абзаца."));
    const text = c.app.pageText(c.a, b, n - 1) catch return c.fail(500, T("Текст книги не читается."));
    const p = snapshot.para(text, para_n) orelse return c.fail(400, T("Нет такого абзаца."));
    const r = findIn(p, c.form.raw("text")) orelse return c.fail(400, T("Выделенный текст не найден в одном абзаце. Выделяйте внутри одного абзаца."));
    const exact = p[r[0]..r[1]];
    if (exact.len > 2000) return c.fail(400, T("Слишком длинный фрагмент (до 2000 знаков)."));
    if (std.mem.eql(u8, c.form.get("kind"), "quote")) {
        if (!c.can(dbm.rights.quote, .quotes)) return c.fail(400, T("Нет права на цитаты, или цитаты отключены."));
        const who = std.math.cast(i32, c.form.int("person") orelse 0) orelse 0;
        var ok = false;
        for (quoteTargets(c, b)) |t| ok = ok or t.id == who;
        if (!ok) return c.fail(400, T("Цитату можно приписать только автору книги или его персонажу."));
        for (c.db.quotes()) |q| {
            if (q.src == 'b' and q.book == id and q.ch == n and q.para == para_n and std.mem.eql(u8, q.text, exact)) return c.fail(400, T("Такая цитата уже есть."));
        }
        const qid = c.db.nextId("quote", 1, 1);
        c.db.putQuote(.{ .id = qid, .person = who, .book = id, .ch = n, .para = para_n, .by = me.user, .date = c.today(), .text = exact });
        return c.redirect("{s}{d}#q{d}", .{ whoPrefix(c, who), who, qid });
    }
    const note = c.form.get("note");
    const mid = c.db.nextId("bookmark", 1, 1);
    c.db.putBookmark(.{ .id = mid, .user = me.user, .book = id, .ch = n, .para = para_n, .date = c.today(), .note = note[0..@min(note.len, 500)], .text = exact });
    c.redirect("/b/{d}/{d}#p{d}", .{ id, n, para_n });
}

/// POST /p/N/mark и /d/N/mark — цитата из стиха, песни или статьи (приписывается их автору).
pub fn textMarkPost(c: *Ctx, src: u8, id: i32) void {
    const me = c.me orelse return c.redirect("/signin", .{});
    var text: []const u8 = undefined;
    var author: i32 = undefined;
    if (src == 'p') {
        const p = c.db.piece(id) orelse return c.notFound();
        text = if (p.chordpro) @import("../chordpro.zig").lyrics(c.a, p.text) else p.text;
        author = p.author;
    } else {
        const d = c.db.draft(id) orelse return c.notFound();
        text = d.text;
        author = d.author;
    }
    if (!c.can(dbm.rights.quote, .quotes)) return c.fail(400, T("Нет права на цитаты, или цитаты отключены."));
    const paras = h.paraList(c.a, text);
    const para_n = std.fmt.parseInt(u32, c.form.get("para"), 10) catch return c.fail(400, T("Нет такого абзаца."));
    if (para_n >= paras.len) return c.fail(400, T("Нет такого абзаца."));
    const r = findIn(paras[para_n], c.form.raw("text")) orelse return c.fail(400, T("Выделенный текст не найден в одном абзаце. Выделяйте внутри одного абзаца."));
    const exact = paras[para_n][r[0]..r[1]];
    if (exact.len > 2000) return c.fail(400, T("Слишком длинный фрагмент (до 2000 знаков)."));
    for (c.db.quotes()) |q| {
        if (q.src == src and q.book == id and q.para == para_n and std.mem.eql(u8, q.text, exact)) return c.fail(400, T("Такая цитата уже есть."));
    }
    const qid = c.db.nextId("quote", 1, 1);
    c.db.putQuote(.{ .id = qid, .person = author, .book = id, .ch = 0, .para = para_n, .by = me.user, .date = c.today(), .text = exact, .src = src });
    c.redirect("{s}{d}#q{d}", .{ whoPrefix(c, author), author, qid });
}

// ───────────── /bookmarks ─────────────

pub fn bookmarksPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    const me = c.me orelse return c.notFound();
    w.s("<h2>Мои закладки</h2>");
    c.msgBox(msg);
    w.s("\n<p class=\"muted\">Закладки видны только вам. Ставятся на странице чтения: выделите текст и нажмите правую кнопку мыши.</p>\n");
    const mine = c.db.bookmarks(me.user);
    if (mine.len == 0) w.s("<p class=\"muted\">Закладок пока нет.</p>");
    // по книгам, в порядке первой закладки
    var done = std.AutoHashMap(i32, void).init(c.a);
    for (mine) |first| {
        if (done.contains(first.book)) continue;
        done.put(first.book, {}) catch {};
        const title = if (c.db.s.book(first.book)) |b| c.db.s.str(b.title) else std.fmt.allocPrint(c.a, "#{d}", .{first.book}) catch "#";
        w.f("<h3><a href=\"{U}/b/{d}{E}\">{h}</a></h3>", .{ first.book, title });
        for (mine) |m| {
            if (m.book != first.book) continue;
            w.f("<div class=\"box\"><a name=\"m{d}\"></a><a href=\"{U}/b/{d}/{d}#p{d}{E}\">стр. {d}, абзац {d}</a> <span class=\"muted\">{h}</span>\n<blockquote>{h}</blockquote>\n<form action=\"/bookmarks/note\" method=\"post\" style=\"margin:0\">", .{ m.id, m.book, m.ch, m.para, m.ch, m.para + 1, m.date, m.text });
            c.post();
            w.f("<input type=\"hidden\" name=\"id\" value=\"{d}\">Примечание: <input name=\"note\" size=\"40\" value=\"{h}\"> <input type=\"submit\" value=\"Сохранить\"></form>\n<form action=\"/bookmarks/del\" method=\"post\" style=\"margin:4px 0 0\">", .{ m.id, m.note });
            c.post();
            w.f("<input type=\"hidden\" name=\"id\" value=\"{d}\"><input type=\"submit\" value=\"Удалить закладку\"></form></div>", .{m.id});
        }
    }
    c.page(.{ .title = T("Закладки"), .crumbs = &.{.{ .text = T("Закладки") }} });
}

pub fn bookmarkPost(c: *Ctx, what: []const u8) void {
    const me = c.me.?;
    const del = std.mem.eql(u8, what, "del");
    if (!del and !std.mem.eql(u8, what, "note")) return c.notFound();
    const id = c.form.int("id") orelse 0;
    for (c.db.bookmarks(me.user)) |m| {
        if (m.id != id) continue;
        if (del) {
            c.db.delBookmark(me.user, m.id);
            return bookmarksPage(c, T("Закладка удалена."));
        }
        var x = m;
        const note = c.form.get("note");
        x.note = note[0..@min(note.len, 500)];
        c.db.putBookmark(x);
        return bookmarksPage(c, T("Примечание сохранено."));
    }
    bookmarksPage(c, T("Нет такой закладки."));
}

// ───────────── /c: люди, персонажи, цитаты ─────────────

fn isEnd(ch: u8) bool {
    return ch == '.' or ch == '!' or ch == '?' or ch == 0x85;
}

/// Первые `sz` предложений текста.
fn sentences(a: std.mem.Allocator, text: []const u8, sz: usize) []const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len and n < sz) : (n += 1) {
        const start = i;
        while (i < text.len and !isEnd(text[i])) i += 1;
        while (i < text.len and isEnd(text[i])) i += 1;
        if (i < text.len and (text[i] == '"' or text[i] == 0xBB)) i += 1;
        const s = std.mem.trim(u8, text[start..i], " \n");
        while (i < text.len and isSpace(text[i])) i += 1;
        if (s.len == 0) continue;
        if (out.items.len > 0) out.append(' ') catch break;
        out.appendSlice(s) catch break;
    }
    return out.items;
}

/// Фильтр цитаты: от `op`, до `ed` включительно, не больше `sz` предложений.
pub fn cut(a: std.mem.Allocator, text: []const u8, op: []const u8, ed: []const u8, sz: usize) ?[]const u8 {
    var t = text;
    if (op.len > 0) t = t[cp.indexOfFold(t, op) orelse return null ..];
    if (ed.len > 0) t = t[0 .. (cp.indexOfFold(t, ed) orelse return null) + ed.len];
    if (sz > 0) t = sentences(a, t, sz);
    return t;
}

fn bookTitle(c: *Ctx, id: i32) []const u8 {
    if (c.db.s.book(id)) |b| return c.db.s.str(b.title);
    return std.fmt.allocPrint(c.a, "#{d}", .{id}) catch "#";
}

/// Авторы, у которых могут быть персонажи: все, у кого есть книги (кроме /u/0).
fn charAuthors(c: *Ctx) []i32 {
    var list = std.ArrayList(i32).init(c.a);
    var seen = std.AutoHashMap(i32, void).init(c.a);
    const s = c.db.s;
    for (0..s.books.len) |k| {
        const b = s.bookAt(k);
        if (b.author == 0 or seen.contains(b.author)) continue;
        seen.put(b.author, {}) catch break;
        list.append(b.author) catch break;
        if (list.items.len >= 300) break;
    }
    return list.items;
}

/// Откуда цитата: «книга», стр. N — или «стих» / «статья» со ссылкой на абзац.
pub fn quoteSource(c: *Ctx, q: dbm.Quote) void {
    const w = &c.w;
    switch (q.src) {
        'p' => {
            const title = if (c.db.piece(q.book)) |p| p.title else (std.fmt.allocPrint(c.a, "#{d}", .{q.book}) catch "#");
            w.f("«<a href=\"{U}/p/{d}#p{d}{E}\">{h}</a>»", .{ q.book, q.para, title });
        },
        'd' => {
            const title = if (c.db.draft(q.book)) |d| d.title else (std.fmt.allocPrint(c.a, "#{d}", .{q.book}) catch "#");
            w.f("«<a href=\"{U}/d/{d}#p{d}{E}\">{h}</a>»", .{ q.book, q.para, title });
        },
        else => w.f("«<a href=\"{U}/b/{d}{E}\">{h}</a>», <a href=\"{U}/b/{d}/{d}#p{d}{E}\">стр. {d}</a>", .{ q.book, bookTitle(c, q.book), q.book, q.ch, q.para, q.ch }),
    }
}

pub fn quoteItem(c: *Ctx, q: dbm.Quote, shown: []const u8) void {
    const w = &c.w;
    w.f("<blockquote><a name=\"q{d}\"></a>{h}", .{ q.id, shown });
    if (!std.mem.eql(u8, shown, q.text)) w.s(" <span class=\"muted\">[фрагмент]</span>");
    w.f("<br>\n<span class=\"muted\">— <a href=\"{U}{s}{d}{E}\">{h}</a>, ", .{ whoPrefix(c, q.person), q.person, c.db.name(q.person) });
    quoteSource(c, q);
    w.s(" · выложил ");
    c.aLink(q.by);
    w.f(" {h}</span></blockquote>", .{q.date});
}

fn bookLinks(c: *Ctx, csv: []const u8) void {
    var it = std.mem.splitScalar(u8, csv, ',');
    var first = true;
    while (it.next()) |x| {
        const id = std.fmt.parseInt(i32, x, 10) catch continue;
        if (!first) c.w.raw(", ");
        first = false;
        c.w.f("<a href=\"{U}/b/{d}{E}\">{h}</a>", .{ id, bookTitle(c, id) });
    }
}

pub fn personIndex(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    const s = c.db.s;
    const quotes = c.db.quotes();
    const chars = c.db.characters();
    const authors = charAuthors(c);
    w.s("<h2>Цитаты</h2>");
    c.msgBox(msg);
    w.s("\n<p>Цитаты делаются только из книг: откройте книгу, выделите фрагмент и нажмите правую кнопку мыши. Цитату приписывают автору книги или его персонажу.</p>\n<h3>Авторы</h3>");
    var t = h.Table.begin(c, &.{ "Автор", "Годы", "Цитат", "Персонажей" });
    for (authors) |id| {
        var nq: usize = 0;
        for (quotes) |q| nq += @intFromBool(q.person == id);
        var nc: usize = 0;
        for (chars) |p| nc += @intFromBool(p.author == id);
        t.row();
        const years: []const u8 = if (c.db.person(id)) |p| (if (p.years.len > 0) p.years else if (id < 0) T("автор сайта") else "") else if (id < 0) T("автор сайта") else "";
        w.f("<td><a href=\"{U}{s}{d}{E}\">{h}</a></td><td>{h}</td><td>{d}</td><td>{d}</td></tr>", .{ whoPrefix(c, id), id, c.db.name(id), years, nq, nc });
    }
    t.end();
    w.s("\n<h3><a name=\"chars\"></a>Персонажи</h3>");
    t = h.Table.begin(c, &.{ "№", "Персонаж", "Автор", "Книги", "Цитат" });
    for (chars) |p| {
        var nq: usize = 0;
        for (quotes) |q| nq += @intFromBool(q.person == p.id);
        t.row();
        w.f("<td>{d}</td><td><a href=\"{U}/c/{d}{E}\">{h}</a></td><td>", .{ p.id, p.id, p.name });
        c.aLink(p.author);
        w.raw("</td><td>");
        if (p.books.len > 0) bookLinks(c, p.books) else w.s("<span class=\"muted\">все книги автора</span>");
        w.f("</td><td>{d}</td></tr>", .{nq});
    }
    t.end();
    w.s("\n<h3>Последние цитаты</h3>");
    var k: usize = quotes.len;
    while (k > quotes.len -| 5) {
        k -= 1;
        quoteItem(c, quotes[k], quotes[k].text);
    }
    w.s("\n<h3>Завести персонажа</h3>");
    if (h.gate(c, dbm.rights.quote, .quotes)) {
        w.raw("<form action=\"/c/new\" method=\"post\" class=\"box\">");
        c.post();
        w.s("\n<table><tr><td>Имя</td><td><input name=\"name\" size=\"30\"></td></tr>\n<tr><td>Автор</td><td><select name=\"author\">");
        for (authors) |id| w.f("<option value=\"{d}\">{h}</option>", .{ id, c.db.name(id) });
        w.s("</select></td></tr>\n<tr><td valign=\"top\">Книги</td><td>");
        for (authors, 0..) |a_id, i| {
            if (i > 0) w.raw("<br>");
            w.f("<b>{h}:</b> ", .{c.db.name(a_id)});
            var first = true;
            for (0..s.books.len) |bi| {
                const b = s.bookAt(bi);
                if (b.author != a_id) continue;
                if (!first) w.byte(' ');
                first = false;
                w.f("<label><input type=\"checkbox\" name=\"book\" value=\"{d}\"> {h}</label>", .{ b.id, s.str(b.title) });
            }
        }
        w.s("\n<br><span class=\"muted\">Не отмечено — персонаж относится ко всему, что написал автор. Отмечаются только книги выбранного автора.</span></td></tr>\n<tr><td>О персонаже</td><td><input name=\"about\" size=\"40\"></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"Завести персонажа\"></td></tr></table></form>");
    }
    c.page(.{ .title = T("Цитаты"), .sec = "/c", .crumbs = &.{.{ .text = T("Цитаты") }} });
}

fn renderQuotes(c: *Ctx, list: []const dbm.Quote, id: i32, of_characters: bool, chars: []const dbm.Person, op: []const u8, ed: []const u8, sz: usize) usize {
    var n: usize = 0;
    for (list) |q| {
        if (of_characters) {
            var mine = false;
            for (chars) |ch| mine = mine or (ch.id == q.person and ch.author == id);
            if (!mine) continue;
        } else if (q.person != id) continue;
        const shown = cut(c.a, q.text, op, ed, sz) orelse continue;
        quoteItem(c, q, shown);
        n += 1;
    }
    return n;
}

pub fn person(c: *Ctx, id: i32, msg: []const u8) void {
    const w = &c.w;
    const s = c.db.s;
    const p = c.db.person(id) orelse return c.notFound();
    const op = c.q("op");
    const ed = c.q("ed");
    const sz_raw = c.qInt("sz");
    const sz: usize = if (sz_raw != 0) @intCast(std.math.clamp(sz_raw, 1, 30)) else 0;
    const chars = c.db.characters();
    const quotes = c.db.quotes();

    w.f("<h2>{h} ", .{p.name});
    if (id < 0) w.s("<span class=\"muted\">(персонаж)</span>");
    w.raw("</h2>");
    c.msgBox(msg);
    w.f("\n<div class=\"muted\">{h} <code>/c/{d}</code></div><p>{h}</p>", .{ p.years, id, p.about });
    if (id > 0) {
        const profile = @import("profile.zig");
        @import("poems.zig").authorUsers(c, id);
        @import("voice.zig").forAuthor(c, id);
        profile.show(c, id, if (profile.canEditPerson(c, id)) (std.fmt.allocPrint(c.a, "/c/{d}/edit", .{id}) catch null) else null);
        var n: usize = 0;
        if (c.secListed(.p)) for (0..s.pieces.len) |k| {
            const x = s.pieceAt(k);
            if (x.author != id) continue;
            if (n == 0) w.s("\n<h3>Стихи и песни</h3><ul>");
            n += 1;
            w.f("<li><a href=\"{U}/p/{d}{E}\">{h}</a> <span class=\"muted\">{h}</span></li>", .{ x.id, s.str(x.title), s.str(x.genre) });
        };
        if (n > 0) w.raw("</ul>");
        n = 0;
        if (c.secListed(.b)) for (0..s.books.len) |k| {
            const b = s.bookAt(k);
            if (b.author != id) continue;
            if (n == 0) w.s("\n<h3>Книги</h3><ul>");
            n += 1;
            w.f("<li><a href=\"{U}/b/{d}{E}\">{h}</a></li>", .{ b.id, s.str(b.title) });
        };
        if (n > 0) w.raw("</ul>");
        n = 0;
        for (chars) |ch| {
            if (ch.author != id) continue;
            if (n == 0) w.s("\n<p>Персонажи: ") else w.raw(", ");
            n += 1;
            w.f("<a href=\"{U}/c/{d}{E}\">{h}</a>", .{ ch.id, ch.name });
        }
        if (n > 0) w.raw("</p>");
    } else {
        w.s("<p>Автор: ");
        c.aLink(p.author);
        w.s(" · книги: ");
        if (p.books.len > 0) bookLinks(c, p.books) else w.s("все книги автора");
        w.raw("</p>");
        if (h.gate(c, dbm.rights.quote, .quotes)) {
            w.f("<form action=\"/c/{d}/books\" method=\"post\" class=\"box\">", .{id});
            c.post();
            w.s("<b>Привязка к книгам</b><br>\n");
            var n: usize = 0;
            for (0..s.books.len) |k| {
                const b = s.bookAt(k);
                if (b.author != p.author) continue;
                if (n > 0) w.raw("<br>");
                n += 1;
                w.f("<label><input type=\"checkbox\" name=\"book\" value=\"{d}\"{s}> {h}</label>", .{ b.id, if (p.books.len > 0 and dbm.Db.charInBook(p.books, b.id)) " checked" else "", s.str(b.title) });
            }
            if (n == 0) w.s("<span class=\"muted\">у автора нет книг в библиотеке</span>");
            w.s("\n<br><span class=\"muted\">Ничего не отмечено — персонаж относится ко всему, что написал автор.</span><br><input type=\"submit\" value=\"Сохранить\"></form>");
        }
    }
    if (id > 0) {
        // у автора — его стихи и книги; цитаты — в разделе /c
        c.page(.{ .title = p.name, .sec = "/c", .crumbs = &.{ .{ .text = T("Цитаты"), .href = "/c" }, .{ .text = T("Авторы"), .href = "/c" }, .{ .text = p.name } } });
        return;
    }
    w.f("\n<form action=\"/c/{d}\" method=\"get\" class=\"box\">", .{id});
    c.hidden();
    w.f("Начало: <input name=\"op\" size=\"14\" value=\"{h}\"> Конец: <input name=\"ed\" size=\"14\" value=\"{h}\"> Предложений: <select name=\"sz\"><option value=\"\">все</option>", .{ op, ed });
    var k: usize = 1;
    while (k <= 30) : (k += 1) w.f("<option{s}>{d}</option>", .{ if (sz == k) " selected" else "", k });
    w.s("</select> <input type=\"submit\" value=\"Показать\"> ");
    if (op.len > 0 or ed.len > 0 or sz > 0) w.f("<a href=\"{U}/c/{d}{E}\">сбросить</a>", .{id});
    w.s("</form><h3>Цитаты</h3>");
    if (renderQuotes(c, quotes, id, false, chars, op, ed, sz) == 0) w.s("<p class=\"muted\">Нет цитат (или ничего не найдено по фильтру).</p>");
    if (id > 0) {
        var any = false;
        for (quotes) |q| {
            for (chars) |ch| any = any or (ch.id == q.person and ch.author == id);
        }
        if (any) {
            w.s("\n<h3>Цитаты персонажей</h3>");
            if (renderQuotes(c, quotes, id, true, chars, op, ed, sz) == 0) w.s("<p class=\"muted\">Нет цитат (или ничего не найдено по фильтру).</p>");
        }
    }
    c.page(.{ .title = p.name, .sec = "/c", .crumbs = &.{ .{ .text = T("Цитаты"), .href = "/c" }, .{ .text = if (id > 0) T("Авторы") else T("Персонажи"), .href = "/c" }, .{ .text = p.name } } });
}

/// Книги из формы, принадлежащие автору, — списком через запятую.
fn formBooks(c: *Ctx, author: i32) []const u8 {
    var out = std.ArrayList(u8).init(c.a);
    for (c.form.fields) |f| {
        if (!std.mem.eql(u8, f.name, "book")) continue;
        const id = std.fmt.parseInt(i32, std.mem.trim(u8, f.value, " "), 10) catch continue;
        const b = c.db.s.book(id) orelse continue;
        if (b.author != author) continue;
        if (out.items.len > 0) out.append(',') catch break;
        out.writer().print("{d}", .{id}) catch break;
    }
    return out.items;
}

/// POST /c/new и /c/-N/books
pub fn characterPost(c: *Ctx, a: []const u8, is_new: bool) void {
    const allowed = c.can(dbm.rights.quote, .quotes);
    if (is_new) {
        if (!allowed) return personIndex(c, T("Нет права заводить персонажей."));
        const name_full = c.form.get("name");
        const name = name_full[0..@min(name_full.len, 80)];
        const author = std.math.cast(i32, c.form.int("author") orelse 0) orelse 0;
        if (name.len == 0) return personIndex(c, T("Укажите имя."));
        if (std.mem.indexOfScalar(i32, charAuthors(c), author) == null) return personIndex(c, T("Нет такого автора."));
        for (c.db.characters()) |p| {
            if (p.author == author and cp.eqlFold(p.name, name)) return personIndex(c, T("У этого автора уже есть персонаж с таким именем."));
        }
        var id: i32 = undefined;
        while (true) {
            id = c.db.nextId("character", -1, -1);
            if (!c.db.isUser(id) and c.db.person(id) == null) break;
        }
        const about = c.form.get("about");
        c.db.putCharacter(.{ .id = id, .name = name, .about = about[0..@min(about.len, 300)], .author = author, .books = formBooks(c, author) });
        return personIndex(c, std.fmt.allocPrint(c.a, "{s}{s}{s}", .{ T("Персонаж «"), name, T("» заведён.") }) catch "");
    }
    const id = std.fmt.parseInt(i32, a, 10) catch return c.notFound();
    if (id >= 0) return c.notFound();
    var p = c.db.person(id) orelse return c.notFound();
    if (!allowed) return person(c, id, T("Нет права заводить персонажей."));
    p.books = formBooks(c, p.author);
    c.db.putCharacter(p);
    person(c, id, T("Привязка к книгам сохранена."));
}

test "поиск фрагмента и фильтр цитаты" {
    try std.testing.expectEqual([2]usize{ 2, 8 }, findIn("a b  c\nd e", " b c d ").?);
    try std.testing.expect(findIn("abc", "abd") == null);
    try std.testing.expect(findIn("abc", "   ") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Two! Three?", cut(a, "One. Two! Three? Four.", "two", "", 2).?);
    try std.testing.expectEqualStrings("One. Two", cut(a, "One. Two! Three?", "", "TWO", 0).?);
    try std.testing.expect(cut(a, "One.", "zzz", "", 0) == null);
}
