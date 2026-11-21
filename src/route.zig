//! Адреса → обработчики. Повторяет `server.ts` макета: те же пути, коды
//! ответов и переадресации.

const std = @import("std");
const sections = @import("sections.zig");
const cp = @import("cp1251.zig");
const http = @import("http.zig");
const theme = @import("theme.zig");
const sys = @import("sys.zig");
const dbm = @import("db.zig");
const W = @import("out.zig").W;
const app_mod = @import("app.zig");
const Ctx = app_mod.Ctx;
const layout = @import("layout.zig");
const main_pages = @import("pages/main.zig");
const books = @import("pages/books.zig");
const marks = @import("pages/marks.zig");
const drafts = @import("pages/drafts.zig");
const forum = @import("pages/forum.zig");
const account = @import("pages/account.zig");
const embed = @import("pages/embed.zig");
const fed_pages = @import("pages/fed.zig");
const poems = @import("pages/poems.zig");
const profile = @import("pages/profile.zig");
const voice = @import("pages/voice.zig");
const exp = @import("export.zig");
const badge = @import("badge.zig");

const T = cp.text;

/// Целое ≠ 0 (или > 0 при `pos`), без ведущих нулей и знака «+».
pub fn intId(s: []const u8, pos: bool) ?i32 {
    if (s.len == 0 or s.len > 11) return null;
    const digits = if (s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    const n = std.fmt.parseInt(i32, s, 10) catch return null;
    if (n == 0 or (pos and n < 0)) return null;
    return n;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0 or s.len > 10) return false;
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn dispatch(c: *Ctx) void {
    const seg = c.seg;
    if (seg.len > 6) return c.notFound();
    const s: []const u8 = if (seg.len > 0) seg[0] else "";
    if (c.req.method == .POST) {
        c.form = http.parseForm(c.a, c.req.content_type, c.body) catch return c.fail(400, T("Форма не разобрана."));
        // m и t формы важнее адреса: так они переживают POST
        const fm = c.form.get("m");
        const ft = c.form.get("t");
        if (fm.len > 0 or ft.len > 0) {
            if (fm.len > 0) c.m_raw = fm;
            if (ft.len > 0) c.t_raw = ft;
            c.setTm();
        }
        if (c.new_csrf or !eq(c.form.get("_csrf"), &c.csrf)) return c.denied(T("Форма устарела или отправлена с чужого сайта (CSRF). Обновите страницу и повторите."));
        return post(c);
    }
    // служебное: без счётчиков и кэша страниц
    if (seg.len == 1 and (eq(s, "favicon.ico") or eq(s, "logo64.png") or eq(s, "logo96.png") or eq(s, "logo120.png"))) return art(c, s);
    if (eq(s, "css") and seg.len == 2) return css(c, seg[1]);
    if (eq(s, "g") and seg.len == 3) return gradient(c, seg[1], seg[2]);
    if (eq(s, "img") and seg.len == 2) return forum.image(c, seg[1]);
    if (eq(s, "img") and seg.len == 3 and eq(seg[1], "b")) return books.bookImage(c, seg[2]);
    if (eq(s, "x") and seg.len == 3) return badge.serve(c, seg[1], seg[2]);
    if (eq(s, "fed") and seg.len == 2) {
        if (eq(seg[1], "in")) return fed_pages.inGet(c);
        if (eq(seg[1], "verify")) return fed_pages.verifyGet(c);
        if (eq(seg[1], "from")) return fed_pages.fromGet(c);
        return c.notFound();
    }

    c.app.views += 1;
    countReading(c);
    if (c.app.cacheLookup(c)) return;
    get(c);
}

/// Прочтение считается до кэша страниц: готовая страница тоже прочтение.
fn countReading(c: *Ctx) void {
    const seg = c.seg;
    if (seg.len < 2) return;
    const reading = (eq(seg[0], "b") and seg.len == 3 and allDigits(seg[2])) or (eq(seg[0], "q") and seg.len == 2);
    if (!reading or !allDigits(seg[1])) return;
    const id = std.fmt.parseInt(i32, seg[1], 10) catch return;
    if (id == 0 and seg.len == 2) return; // /q/0 не открывается
    const b = c.db.s.book(id) orelse return;
    if (seg.len == 3) {
        const k = std.fmt.parseInt(u32, seg[2], 10) catch return;
        if (k < 1 or k > b.n_pages) return;
    }
    c.app.countRead(id, false);
}

/// Раздел по первой части адреса (null — адрес не раздела).
fn sectionFor(s: []const u8) ?sections.Sec {
    if (eq(s, "p")) return .p;
    if (eq(s, "b") or eq(s, "q") or eq(s, "bookmarks")) return .b;
    if (eq(s, "d")) return .d;
    if (eq(s, "f")) return .f;
    if (eq(s, "c")) return .q;
    if (eq(s, "v")) return .v;
    return null;
}

/// Флаги запуска (-N, -G) и скрытые книги цитатника. true — запрос уже обработан.
fn sectionGate(c: *Ctx) bool {
    const seg = c.seg;
    const sec = sectionFor(seg[0]) orelse return false;
    const rules = c.app.cfg.sec;
    if (!rules.exists(sec)) {
        c.notFound();
        return true;
    }
    if (!c.secReadable(sec)) {
        c.redirect("/signin?back={s}", .{c.req.path});
        return true;
    }
    if (sec == .b and rules.booksHidden()) {
        // книги цитатника: только сама книга и её страницы чтения
        const s = seg[0];
        const a: []const u8 = if (seg.len > 1) seg[1] else "";
        const ok = c.req.method != .POST and allDigits(a) and
            ((eq(s, "b") and (seg.len == 2 or (seg.len == 3 and allDigits(seg[2])))) or (eq(s, "q") and seg.len == 2));
        if (!ok) {
            c.notFound();
            return true;
        }
    }
    return false;
}

fn get(c: *Ctx) void {
    const seg = c.seg;
    if (seg.len == 0) return main_pages.home(c);
    if (sectionGate(c)) return;
    const s = seg[0];
    const a: []const u8 = if (seg.len > 1) seg[1] else "";
    const b: []const u8 = if (seg.len > 2) seg[2] else "";
    if (eq(s, "help") and seg.len == 1) return main_pages.help(c);
    if (eq(s, "theme") and seg.len == 1) return layout.themePage(c);
    if (eq(s, "fed") and seg.len == 1) return fed_pages.page(c, "");
    if (eq(s, "s") and seg.len == 1) return main_pages.search(c);
    if (eq(s, "signin") and seg.len == 1) return account.signinPage(c, "");
    if (eq(s, "signup") and seg.len == 1) return account.signupPage(c, "");
    if (eq(s, "logout") and seg.len == 1) return if (c.me != null) account.logoutPage(c, "") else c.redirect("/signin?back=/logout", .{});
    if (eq(s, "panel") and seg.len == 1) return if (c.me != null) account.panelPage(c, "") else c.redirect("/signin?back=/panel", .{});
    if (eq(s, "bookmarks") and seg.len == 1) return if (c.me != null) marks.bookmarksPage(c, "") else c.redirect("/signin?back=/bookmarks", .{});
    if (eq(s, "files") and seg.len >= 2) return files(c);
    if (eq(s, "e") and seg.len == 1) return embed.demo(c);
    if (eq(s, "e") and seg.len <= 3) return embed.serve(c, a, b);

    if (s.len == 1 and std.mem.indexOfScalar(u8, "pbqcd", s[0]) != null and !layout.sectionOn(c, c.req.path[0..2]) and !(sectionFor(s) == .b and c.app.cfg.sec.booksHidden())) return c.denied(T("Раздел отключён администратором."));
    const id: ?i32 = if (eq(s, "b") and eq(a, "0")) 0 else intId(a, false);
    if (eq(s, "p")) {
        if (seg.len == 2 and eq(a, "new")) return poems.newPage(c, "");
        if (seg.len == 3 and eq(b, "edit")) return poems.editPage(c, id orelse return c.notFound(), "");
        if (seg.len > 2) return c.notFound();
        if (seg.len == 1) return main_pages.pieceIndex(c);
        return main_pages.piece(c, id orelse return c.notFound());
    }
    if (eq(s, "b")) {
        if (seg.len == 1) return books.index(c);
        if (eq(a, "upload") and seg.len == 2) return books.uploadPage(c, "");
        if (id == null or seg.len > 3) return c.notFound();
        if (seg.len == 2) return books.book(c, id.?);
        if (id.? < 0) return c.notFound(); // у серий нет страниц
        if (eq(b, "txt") or eq(b, "fb2") or eq(b, "epub")) return exp.download(c, id.?, b);
        if (allDigits(b)) return books.read(c, id.?, std.fmt.parseInt(u32, b, 10) catch return c.notFound());
        // комментарии: -n или -родитель-n
        if (b.len > 1 and b[0] == '-') {
            var it = std.mem.splitScalar(u8, b[1..], '-');
            const first = it.next() orelse "";
            const second = it.next();
            if (it.next() != null or !allDigits(first) or (second != null and !allDigits(second.?))) return c.notFound();
            return books.comment(c, id.?, std.fmt.parseInt(i32, first, 10) catch return c.notFound(), if (second) |x| (std.fmt.parseInt(i32, x, 10) catch return c.notFound()) else null);
        }
        return c.notFound();
    }
    if (eq(s, "q")) {
        if (seg.len == 1) return c.redirect("/b", .{});
        if (seg.len > 2) return c.notFound();
        return books.read(c, intId(a, true) orelse return c.notFound(), null);
    }
    if (eq(s, "c")) {
        if (seg.len == 3 and eq(b, "edit")) return profile.editPerson(c, id orelse return c.notFound(), "");
        if (seg.len > 2) return c.notFound();
        if (seg.len == 1) return marks.personIndex(c, "");
        return marks.person(c, id orelse return c.notFound(), "");
    }
    if (eq(s, "d")) {
        if (seg.len > 2) return c.notFound();
        if (seg.len == 1) return drafts.index(c, "");
        return drafts.draft(c, id orelse return c.notFound());
    }
    if (eq(s, "v")) {
        if (!voice.enabled) return c.notFound();
        if (seg.len == 1) return voice.index(c);
        if (seg.len == 2 and eq(a, "new")) return voice.newPage(c, "");
        if (seg.len == 2 and std.mem.endsWith(u8, a, ".mp3")) return voice.serve(c, intId(a[0 .. a.len - 4], true) orelse return c.notFound());
        const vid = intId(a, false) orelse return c.notFound();
        if (seg.len == 3 and eq(b, "edit")) return if (vid < 0) voice.readerEditPage(c, vid, "") else voice.editPage(c, vid, "");
        if (seg.len > 2) return c.notFound();
        return if (vid < 0) voice.reader(c, vid) else voice.recording(c, vid);
    }
    if (eq(s, "u")) {
        if (seg.len == 3 and eq(b, "edit")) return profile.editUser(c, if (eq(a, "0")) 0 else (id orelse return c.notFound()), "");
        if (seg.len > 2) return c.notFound();
        if (seg.len == 1) return main_pages.userIndex(c);
        if (eq(a, "0")) return main_pages.user(c, 0);
        return main_pages.user(c, id orelse return c.notFound());
    }
    if (eq(s, "f")) {
        if (seg.len > 2) return c.notFound();
        if (seg.len == 1) return forum.index(c);
        if (allDigits(a)) {
            if (!c.featureOpen(.forum)) return c.denied(T("Форум отключён."));
            return forum.forum(c, intId(a, true) orelse return c.notFound());
        }
        if (!c.featureOpen(.boards)) return c.denied(T("Доски отключены."));
        if (a.len < 1 or a.len > 8) return c.notFound();
        const low = std.ascii.allocLowerString(c.a, a) catch return c.notFound();
        for (low) |ch| if (!std.ascii.isAlphanumeric(ch)) return c.notFound();
        return forum.board(c, low);
    }
    return c.notFound();
}

fn post(c: *Ctx) void {
    const seg = c.seg;
    const s: []const u8 = if (seg.len > 0) seg[0] else "";
    const a: []const u8 = if (seg.len > 1) seg[1] else "";
    const b: []const u8 = if (seg.len > 2) seg[2] else "";
    if (seg.len > 0 and sectionGate(c)) return;
    if (eq(s, "logout")) return account.logoutPost(c);
    if (eq(s, "signin")) return account.signinPost(c);
    if (eq(s, "signup")) return account.signupPost(c);
    if (eq(s, "fed") and eq(a, "out") and seg.len == 2) return fed_pages.outPost(c);
    if (eq(s, "panel") and seg.len == 2) {
        if (c.me == null) return c.redirect("/signin?back=/panel", .{});
        return account.panelPost(c, a);
    }
    // закладки, цитаты, персонажи
    if (eq(s, "bookmarks") and seg.len == 2) {
        if (c.me == null) return c.redirect("/signin?back=/bookmarks", .{});
        return marks.bookmarkPost(c, a);
    }
    if (eq(s, "b") and seg.len == 4 and eq(seg[3], "mark")) return marks.markPost(c, a, b);
    if (eq(s, "c") and ((eq(a, "new") and seg.len == 2) or (eq(b, "books") and seg.len == 3))) {
        if (c.me == null) return c.redirect("/signin?back=/c", .{});
        return marks.characterPost(c, a, eq(a, "new"));
    }
    if ((eq(s, "p") or eq(s, "d")) and seg.len == 3 and eq(b, "mark")) return marks.textMarkPost(c, s[0], intId(a, false) orelse return c.notFound());
    if (eq(s, "d")) return drafts.post(c, a, b);
    if (eq(s, "p") and seg.len == 2 and eq(a, "new")) return poems.newPost(c);
    if (eq(s, "p") and seg.len == 3 and (eq(b, "edit") or eq(b, "delete"))) {
        const pid = intId(a, false) orelse return c.notFound();
        return if (eq(b, "edit")) poems.editPost(c, pid) else poems.deletePost(c, pid);
    }
    if (eq(s, "c") and seg.len == 3 and eq(b, "edit")) return profile.editPersonPost(c, intId(a, true) orelse return c.notFound());
    if (eq(s, "u") and seg.len == 3 and eq(b, "edit")) return profile.editUserPost(c, if (eq(a, "0")) 0 else (intId(a, false) orelse return c.notFound()));
    if (eq(s, "u") and seg.len == 3 and eq(b, "authors")) return poems.authorsPost(c, intId(a, false) orelse return c.notFound());
    if (eq(s, "u") and seg.len == 3 and eq(b, "readers") and voice.enabled) return voice.readersPost(c, intId(a, false) orelse return c.notFound());
    if (eq(s, "v") and voice.enabled) {
        if (seg.len == 2 and eq(a, "new")) return voice.newPost(c);
        const vid = intId(a, false) orelse return c.notFound();
        if (seg.len == 3 and eq(b, "edit")) return if (vid < 0) voice.readerEditPost(c, vid) else voice.editPost(c, vid);
        if (seg.len == 3 and eq(b, "delete") and vid > 0) return voice.deletePost(c, vid);
        return c.notFound();
    }
    if (eq(s, "b") and eq(a, "upload") and seg.len == 2) return books.uploadPost(c);
    if (eq(s, "b") and eq(b, "comment") and seg.len == 3) return books.commentPost(c, a);
    if (eq(s, "b") and eq(b, "source") and seg.len == 3) return books.sourcePost(c, if (eq(a, "0")) 0 else (intId(a, true) orelse return c.notFound()));
    if (eq(s, "b") and eq(b, "voice") and seg.len == 3 and voice.enabled) return voice.linkPost(c, 'b', if (eq(a, "0")) 0 else (intId(a, true) orelse return c.notFound()));
    if (eq(s, "p") and eq(b, "voice") and seg.len == 3 and voice.enabled) return voice.linkPost(c, 'p', intId(a, false) orelse return c.notFound());
    if (eq(s, "f") and seg.len == 3 and allDigits(a)) return forum.forumPost(c, a, b);
    if (eq(s, "f") and seg.len == 3 and eq(b, "post")) return forum.boardPost(c, a);
    c.notFound();
}

// ───────────── статика ─────────────

const art_files = .{
    .{ "favicon.ico", "image/x-icon", @embedFile("tpl/art/favicon.ico") },
    .{ "logo64.png", "image/png", @embedFile("tpl/art/logo64.png") },
    .{ "logo96.png", "image/png", @embedFile("tpl/art/logo96.png") },
    .{ "logo120.png", "image/png", @embedFile("tpl/art/logo120.png") },
};

/// Время сборки бинарника неизвестно без часов сборки; статика помечается
/// ETag по содержимому.
fn etagOf(c: *Ctx, bytes: []const u8) []const u8 {
    return std.fmt.allocPrint(c.a, "\"{x:0>8}-{x}\"", .{ std.hash.Crc32.hash(bytes), bytes.len }) catch "\"0\"";
}

/// Отдаёт неизменяемые байты с ETag; на совпавший If-None-Match — 304.
pub fn cached(c: *Ctx, ctype: []const u8, bytes: []const u8, max_age: u32) void {
    const tag = etagOf(c, bytes);
    c.reply.header("ETag: {s}", .{tag});
    c.reply.header("Cache-Control: max-age={d}", .{max_age});
    if (c.req.if_none_match.len > 0 and std.mem.indexOf(u8, c.req.if_none_match, tag) != null) {
        c.reply.status = 304;
        c.reply.ctype = ctype;
        return;
    }
    c.send(ctype, bytes);
}

/// Свои значок (-ico) и логотип (-png): прочитаны при старте, отдаются вместо встроенных.
/// Логотип один на все три размера — браузер подгоняет его по атрибутам width и height.
pub var own_ico: ?[]const u8 = null;
pub var own_png: ?[]const u8 = null;

/// Годится ли файл: .ico — заголовок ICONDIR (0, 0, 1, 0), .png — подпись PNG.
pub fn artOk(png: bool, bytes: []const u8) bool {
    if (png) return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n");
    return bytes.len >= 6 and std.mem.eql(u8, bytes[0..4], "\x00\x00\x01\x00") and (bytes[4] != 0 or bytes[5] != 0);
}

fn art(c: *Ctx, name: []const u8) void {
    if (eq(name, "favicon.ico")) if (own_ico) |b| return cached(c, "image/x-icon", b, 86400);
    if (std.mem.startsWith(u8, name, "logo")) if (own_png) |b| return cached(c, "image/png", b, 86400);
    inline for (art_files) |f| if (eq(name, f[0])) return cached(c, f[1], f[2], 86400);
    c.notFound();
}

/// /css/{тема}-{режим}.css — цвета отдельно от разметки. Режим `time`
/// решается здесь, по часам сервера, поэтому кэшируется ненадолго.
fn css(c: *Ctx, file: []const u8) void {
    if (!std.mem.endsWith(u8, file, ".css")) return c.notFound();
    const name = file[0 .. file.len - 4];
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return c.notFound();
    const base = theme.baseOf(name[0..dash]) orelse return c.notFound();
    const mode = std.meta.stringToEnum(theme.Mode, name[dash + 1 ..]) orelse return c.notFound();
    theme.css(&c.out, base, theme.resolve(mode, sys.localHour()));
    cached(c, "text/css", c.out.out(), if (mode == .time) 300 else 86400);
}

fn gradient(c: *Ctx, h: []const u8, file: []const u8) void {
    const spec = if (std.mem.endsWith(u8, file, ".bmp")) file[0 .. file.len - 4] else file;
    const height = std.fmt.parseInt(u32, h, 10) catch return c.notFound();
    const bmp = theme.gradientBmp(c.a, spec, height) orelse return c.notFound();
    cached(c, "image/bmp", bmp, 86400);
}

fn mimeOf(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const map = .{
        .{ ".html", app_mod.html_type }, .{ ".htm", app_mod.html_type }, .{ ".txt", "text/plain; charset=utf-8" }, .{ ".css", "text/css" },
        .{ ".js", "text/javascript" },   .{ ".png", "image/png" },       .{ ".jpg", "image/jpeg" },                .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },        .{ ".bmp", "image/bmp" },       .{ ".ico", "image/x-icon" },              .{ ".svg", "image/svg+xml" },
        .{ ".pdf", "application/pdf" },  .{ ".zip", "application/zip" }, .{ ".fb2", "application/x-fictionbook+xml" }, .{ ".epub", "application/epub+zip" },
        .{ ".mp3", "audio/mpeg" },       .{ ".xml", "text/xml" },        .{ ".json", "application/json" },
    };
    inline for (map) |m| if (std.ascii.eqlIgnoreCase(ext, m[0])) return m[1];
    return "application/octet-stream";
}

/// Одно тело целиком или его диапазон (`Range: bytes=a-b`).
pub fn ranged(c: *Ctx, ctype: []const u8, bytes: []const u8) void {
    c.reply.header("Accept-Ranges: bytes", .{});
    const r = http.parseRange(c.req.range, bytes.len) catch {
        c.reply.status = 416;
        c.reply.ctype = ctype;
        c.reply.header("Content-Range: bytes */{d}", .{bytes.len});
        return;
    };
    if (r) |x| {
        c.reply.status = 206;
        c.reply.ctype = ctype;
        c.reply.body = bytes[@intCast(x[0])..@intCast(x[1])];
        c.reply.header("Content-Range: bytes {d}-{d}/{d}", .{ x[0], x[1] - 1, bytes.len });
        return;
    }
    c.send(ctype, bytes);
}

/// /files/… — файлы из папки, заданной в панели (по умолчанию `files`).
fn files(c: *Ctx) void {
    // Путь раскодируется здесь и только здесь; выйти из папки нельзя.
    var rel = std.ArrayList(u8).init(c.a);
    for (c.seg[1..], 0..) |raw, i| {
        const part = http.urlDecode(c.a, raw) catch return c.notFound();
        if (part.len == 0 or eq(part, ".") or eq(part, "..") or part[0] == '.') return c.notFound();
        for (part) |ch| if (ch == '/' or ch == '\\' or ch == ':' or ch < 0x20) return c.notFound();
        if (i > 0) rel.append('/') catch return c.notFound();
        // имена на диске — UTF-8
        rel.appendSlice(if (cp.looksUtf8(part)) part else cp.toUtf8Alloc(c.a, part) catch return c.notFound()) catch return c.notFound();
    }
    const dir_name = c.db.setting("filesDir") orelse "files";
    var dir = c.app.root.openDir(dir_name, .{}) catch return c.notFound();
    defer dir.close();
    const file = dir.openFile(rel.items, .{}) catch return c.notFound();
    defer file.close();
    const st = file.stat() catch return c.notFound();
    if (st.kind != .file or st.size > 256 << 20) return c.notFound();
    var date: [29]u8 = undefined;
    const mtime: i64 = @intCast(@divFloor(st.mtime, std.time.ns_per_s));
    const lm = http.httpDate(&date, mtime);
    c.reply.header("Last-Modified: {s}", .{lm});
    if (c.req.if_modified_since.len > 0 and eq(c.req.if_modified_since, lm)) {
        c.reply.status = 304;
        return;
    }
    const buf = c.app.gpa.alloc(u8, @intCast(st.size)) catch return c.fail(503, T("Не хватает памяти."));
    const n = file.preadAll(buf, 0) catch 0;
    c.reply.owned = buf;
    ranged(c, mimeOf(rel.items), buf[0..n]);
}
