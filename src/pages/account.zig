//! /signin, /signup, /logout (сеансы), /panel (свои настройки и — для /u/0 —
//! управление сайтом: функции, права участников, папка файлов).

const std = @import("std");
const net = @import("../net/net.zig");
const cp = @import("../cp1251.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const auth = @import("../auth.zig");
const badge = @import("../badge.zig");
const Ctx = @import("../app.zig").Ctx;
const forum = @import("forum.zig");
const theme = @import("../theme.zig");
const import = @import("../import.zig");
const fed = @import("../fed.zig");

const T = cp.text;

fn back(c: *Ctx) []const u8 {
    return Ctx.safeBack(c.q("back"));
}

pub fn signinPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    w.s("<h2>Вход</h2>");
    c.msgBox(msg);
    w.raw("\n<form action=\"/signin\" method=\"post\" class=\"box\">");
    c.post();
    const b = if (c.req.method == .POST) Ctx.safeBack(c.form.get("back")) else back(c);
    w.f("<input type=\"hidden\" name=\"back\" value=\"{h}\">\n<table><tr><td>Логин</td><td><input name=\"login\" size=\"20\"></td></tr><tr><td>Пароль</td><td><input type=\"password\" name=\"pass\" size=\"20\"></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"Войти\"></td></tr></table></form>\n<p>Нет учётной записи? ", .{b});
    if (c.featureOn(.signup)) w.f("<a href=\"{U}/signup{E}\">Регистрация</a>", .{}) else w.s("Регистрация закрыта.");
    w.s("</p>");
    if (c.app.fed.on()) w.f("\n<p>Есть учётная запись на другом сайте федерации? <a href=\"{U}/fed{E}\">Войти с другого сайта</a></p>", .{});
    c.page(.{ .title = T("Вход"), .crumbs = &.{.{ .text = T("Вход") }} });
}

pub fn signupPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    w.s("<h2>Регистрация</h2>");
    c.msgBox(msg);
    w.byte('\n');
    if (!c.featureOn(.signup)) {
        w.s("<p>Регистрация отключена администратором.</p>");
    } else {
        w.raw("<form action=\"/signup\" method=\"post\" class=\"box\">");
        c.post();
        w.s("\n<table><tr><td>Логин</td><td><input name=\"login\" size=\"20\"> <span class=\"muted\">латиница, 3–20</span></td></tr>\n<tr><td>Пароль</td><td><input type=\"password\" name=\"pass\" size=\"20\"></td></tr>\n<tr><td>Ник</td><td><input name=\"nick\" size=\"20\"></td></tr>\n<tr><td>Кто вы</td><td><label><input type=\"radio\" name=\"kind\" value=\"user\" checked> читатель (/u/N, N&gt;0)</label><br><label><input type=\"radio\" name=\"kind\" value=\"author\"> автор — Unveiler / Upbuilder (/u/-N)</label></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"Зарегистрироваться\"></td></tr></table></form>");
    }
    c.page(.{ .title = T("Регистрация"), .crumbs = &.{.{ .text = T("Регистрация") }} });
}

pub fn setSid(c: *Ctx, sid: []const u8) void {
    c.reply.header("Set-Cookie: sid={s}; Path=/; HttpOnly; SameSite=Lax{s}", .{ sid, if (c.tls) "; Secure" else "" });
}

pub fn signinPost(c: *Ctx) void {
    const login = std.ascii.allocLowerString(c.a, c.form.get("login")) catch "";
    const pass = c.form.raw("pass");
    var ok = false;
    if (login.len > 0 and std.mem.eql(u8, login, c.app.admin.login)) {
        // /u/0 нужен, чтобы настроить сайт и завести своего администратора: вход — только с этой машины
        ok = c.isLocal() and auth.verifyPassword(c.app.admin.hash, pass);
    } else if (c.db.account(login)) |acc| {
        ok = !acc.blocked and auth.verifyPassword(acc.hash, pass);
    } else {
        // тот же расход времени, что и при существующем логине
        _ = auth.verifyPassword(c.app.admin.hash, pass);
    }
    if (!ok) {
        c.status = 401;
        return signinPage(c, T("Неверный логин или пароль."));
    }
    setSid(c, auth.startSession(c.db, login, c.req.user_agent, c.ip, c.app.now));
    c.redirect("{s}", .{Ctx.safeBack(c.form.get("back"))});
}

pub fn signupPost(c: *Ctx) void {
    const login = std.ascii.allocLowerString(c.a, c.form.get("login")) catch "";
    const pass = c.form.raw("pass");
    const nick = c.form.get("nick");
    const author = std.mem.eql(u8, c.form.get("kind"), "author");
    const err: ?[]const u8 = blk: {
        if (!c.featureOn(.signup)) break :blk T("Регистрация отключена.");
        if (login.len < 3 or login.len > 20) break :blk T("Логин: 3–20 символов, латиница, цифры, _.");
        for (login) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') break :blk T("Логин: 3–20 символов, латиница, цифры, _.");
        if (pass.len < 4) break :blk T("Пароль: минимум 4 символа.");
        if (pass.len > 200) break :blk T("Пароль слишком длинный.");
        if (std.mem.eql(u8, login, c.app.admin.login) or c.db.account(login) != null) break :blk T("Такой логин уже занят.");
        break :blk null;
    };
    if (err) |e| {
        c.status = 400;
        return signupPage(c, e);
    }
    // номер не должен совпасть ни с человеком, ни с персонажем каталога
    var id: i32 = undefined;
    while (true) {
        id = if (author) c.db.nextId("authorNeg", -101, -1) else c.db.nextId("user", 1001, 1);
        if (!c.db.isUser(id) and c.db.person(id) == null) break;
    }
    c.db.putUser(.{ .id = id, .nick = if (nick.len > 0) nick[0..@min(nick.len, 40)] else login, .joined = c.today(), .about = if (author) T("Автор.") else "", .login = login });
    c.db.putAccount(.{ .login = login, .user = id, .hash = auth.hashPassword(c.a, pass), .rights = dbm.rights.default | (if (author) dbm.rights.upload else 0), .blocked = false });
    setSid(c, auth.startSession(c.db, login, c.req.user_agent, c.ip, c.app.now));
    c.redirect("/panel", .{});
}

/// /logout — все сеансы учётной записи и кнопки (POST + CSRF).
pub fn logoutPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    const me = c.me orelse return c.notFound();
    const list = auth.sessionsOf(c.db, me.login);
    // текущий первым, остальные — по давности активности
    std.mem.sort(auth.Session, list, c.session_key, struct {
        fn lt(cur: []const u8, x: auth.Session, y: auth.Session) bool {
            const xc = std.mem.eql(u8, x.key, cur);
            const yc = std.mem.eql(u8, y.key, cur);
            if (xc != yc) return xc;
            return x.seen > y.seen;
        }
    }.lt);
    w.f("<h2>Сеансы: {h}</h2>", .{c.db.name(me.user)});
    c.msgBox(msg);
    w.s("\n<table class=\"list\"><tr><th></th><th>вход</th><th>активность</th><th>адрес</th><th>браузер</th><th></th></tr>");
    for (list) |s| {
        const cur = std.mem.eql(u8, s.key, c.session_key);
        w.raw("<tr><td>");
        if (cur) w.s("<b>эта</b>");
        w.raw("</td><td>");
        forum.ruTime(w, s.created * 1000);
        w.raw("</td><td>");
        forum.ruTime(w, s.seen * 1000);
        w.f("</td><td>{h}</td><td><span class=\"muted\">{h}</span></td>\n<td><form action=\"/logout\" method=\"post\" style=\"margin:0\">", .{ if (s.ip.len > 0) s.ip else T("—"), s.ua });
        c.post();
        w.f("<input type=\"hidden\" name=\"hid\" value=\"{h}\"><input type=\"submit\" value=\"{s}\"></form></td></tr>", .{ s.hid, if (cur) T("Выйти") else T("Завершить") });
    }
    w.raw("</table>\n<form action=\"/logout\" method=\"post\" class=\"box\">");
    c.post();
    w.f("<input type=\"hidden\" name=\"hid\" value=\"*\"><input type=\"submit\" value=\"Выйти везде ({d})\"></form>\n<p class=\"muted\">Завершение чужого сеанса выкидывает тот браузер со входа. <a href=\"{U}/panel{E}\">Вернуться в панель</a></p>", .{list.len});
    c.page(.{ .title = T("Выход"), .crumbs = &.{ .{ .text = T("Панель"), .href = "/panel" }, .{ .text = T("Сеансы") } } });
}

pub fn logoutPost(c: *Ctx) void {
    const me = c.me orelse return c.redirect("/", .{});
    const hid_raw = c.form.get("hid");
    const cur = auth.endSessions(c.db, me.login, if (hid_raw.len > 0) hid_raw else "-", c.session_key);
    if (cur) {
        c.reply.header("Set-Cookie: sid=; Path=/; Max-Age=0", .{});
        return c.redirect("/", .{});
    }
    logoutPage(c, T("Сеанс завершён."));
}

/// Может ли вошедший менять права и блокировку этой учётной записи.
/// /u/0 — любой; сотрудник — только не-сотрудникам и не себе.
fn rightsEditable(c: *const Ctx, a: dbm.Account) bool {
    if (c.isRoot()) return true;
    const me = c.me orelse return false;
    if (a.user == me.user or std.mem.eql(u8, a.login, me.login)) return false;
    return a.rights & dbm.rights.staff == 0;
}

fn chk(c: *Ctx, name: []const u8, on: bool, disabled: bool) void {
    c.w.f("<input type=\"checkbox\" name=\"{h}\" value=\"1\"{s}{s}>", .{ name, if (on) " checked" else "", if (disabled) " disabled" else "" });
}

fn mine(c: *Ctx, b: anytype) bool {
    const me = c.me.?.user;
    if ((b.uploader == me and (me != 0 or b.id == 0)) or b.author == me) return true;
    // участник, привязанный к автору, распоряжается и его книгами
    for (c.db.authorsOf(me)) |p| if (p == b.author) return true;
    return false;
}

pub fn panelPage(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    const s = c.db.s;
    const me = c.me orelse return c.notFound();
    const u = c.db.user(me.user) orelse dbm.User{ .id = me.user, .nick = me.login, .joined = "", .about = "", .login = me.login };
    w.f("<h2>Панель: {h}</h2>", .{u.nick});
    c.msgBox(msg);
    w.f("\n<p class=\"muted\">логин <b>{h}</b> · профиль <a href=\"{U}/u/{d}{E}\">/u/{d}</a> · <a href=\"{U}/logout{E}\">выйти</a></p>\n<h3>Профиль</h3><form action=\"/panel/profile\" method=\"post\" class=\"box\">", .{ me.login, u.id, u.id });
    c.post();
    if (dbm.Db.external(me.login)) {
        // гость федерации: имя приходит с его сайта, пароля здесь нет
        w.f("\nИмя: <b>{h}</b> <span class=\"muted\">приходит с вашего сайта</span><br>О себе:<br><textarea name=\"about\" rows=\"3\" cols=\"50\">{h}</textarea><br>\n<span class=\"muted\">Пароля здесь нет: вход держится на токене федерации (45 минут бездействия или до закрытия браузера).</span><br><input type=\"submit\" value=\"Сохранить\"></form>\n<h3>Мои права</h3><table class=\"list\">", .{ u.nick, u.about });
    } else w.f("\nНик: <input name=\"nick\" value=\"{h}\" size=\"20\"><br>О себе:<br><textarea name=\"about\" rows=\"3\" cols=\"50\">{h}</textarea><br>\nНовый пароль: <input type=\"password\" name=\"pass\" size=\"16\"> <span class=\"muted\">пусто — не менять</span><br><input type=\"submit\" value=\"Сохранить\"></form>\n<h3>Мои права</h3><table class=\"list\">", .{ u.nick, u.about });
    for (auth.right_names) |r| {
        // «сотрудник» — отметка, а не право из общего набора: видна тем, у кого она есть
        if (r.bit == dbm.rights.staff and me.rights & r.bit == 0) continue;
        w.raw("<tr><td>");
        chk(c, "x", me.rights & r.bit != 0, true);
        w.f("</td><td>{s}</td></tr>", .{r.label});
    }
    w.s("</table>");
    if (c.secListed(.b)) {
        w.s("\n<h3>Мои книги</h3>");
        var n: usize = 0;
        for (0..s.books.len) |k| {
            const b = s.bookAt(k);
            if (!mine(c, b)) continue;
            if (n == 0) {
                w.raw("<form action=\"/panel/books\" method=\"post\">");
                c.post();
                w.s("<table class=\"list\"><tr><th>Книга</th><th>iframe</th><th>Код</th></tr>");
            }
            n += 1;
            w.f("<tr><td><a href=\"{U}/b/{d}{E}\">{h}</a><input type=\"hidden\" name=\"book\" value=\"{d}\"></td><td>", .{ b.id, s.str(b.title), b.id });
            chk(c, std.fmt.allocPrint(c.a, "embed{d}", .{b.id}) catch "", c.db.bookStat(b.id).embed, false);
            w.raw("</td><td><code>&lt;iframe src=&quot;");
            c.origin(w);
            w.f("/e/b/{d}&quot;&gt;</code></td></tr>", .{b.id});
        }
        if (n > 0) w.s("</table><input type=\"submit\" value=\"Сохранить встраивание\"></form>") else w.f("<p class=\"muted\">Нет. <a href=\"{U}/b/upload{E}\">Выложить книгу</a></p>", .{});
    }
    w.f("\n<h3>Мои бейджи и информеры</h3>\n<p><img src=\"/x/u/books.svg?id={d}\" alt=\"\"> <img src=\"/x/u/posts.png?id={d}\" alt=\"\"> <img src=\"/x/u/comments.svg?id={d}&amp;color=blue\" alt=\"\"></p>\n<textarea rows=\"3\" cols=\"70\" readonly style=\"width:100%\">&lt;img src=&quot;", .{ u.id, u.id, u.id });
    c.origin(w);
    w.f("/x/u/books.svg?id={d}&quot;&gt;\n&lt;iframe src=&quot;", .{u.id});
    c.origin(w);
    w.f("/e/u/{d}&quot; width=&quot;240&quot; height=&quot;90&quot; frameborder=&quot;0&quot;&gt;&lt;/iframe&gt;</textarea>", .{u.id});
    if (c.isModerator()) admin(c);
    c.page(.{ .title = T("Панель"), .crumbs = &.{.{ .text = T("Панель") }} });
}

/// Управление сайтом: сотрудники и /u/0 (у /u/0 одна привилегия — права сотрудников, BACKLOG_RU.md §21).
fn admin(c: *Ctx) void {
    const w = &c.w;
    const app = c.app;
    w.s("<hr><h2>Администрирование сайта</h2>\n");
    w.f("\n<h3>Сервер</h3><table class=\"list\">\n<tr><td>Порт</td><td><b>{d}</b> <span class=\"muted\">(флаг <code>-p</code>; {s})</span></td></tr>\n<tr><td>Папка библиотеки</td><td><code>{h}</code> <span class=\"muted\">(флаг <code>-r</code>)</span></td></tr>\n<tr><td>Тема по умолчанию</td><td><b>{s}</b> <span class=\"muted\">(флаг <code>-t</code> или «Оформление» ниже)</span></td></tr>\n<tr><td>Хранилище записей</td><td><b>{s}</b></td></tr>\n<tr><td>Снимок каталога</td><td><code>{h}</code> · книг: {d} · кадров текста: {d}</td></tr>\n<tr><td>Кэш</td><td>кадров: {d} попаданий / {d} промахов · страниц гостей: {d} / {d}</td></tr></table>", .{
        app.cfg.port,                                                       if (c.tls) "https" else "http",
        cp.encodeAlloc(c.a, app.cfg.root) catch "",                         @tagName(app.look.base),
        if (app.cfg.btree) T("B+ дерево (clipper.tree)") else T("журнал (clipper.journal)"), app.snap_name[0..app.snap_name_len],
        c.db.s.books.len,                                                   c.db.s.frames.len,
        app.frames.hits,                                                    app.frames.misses,
        app.pcache.hits,                                                    app.pcache.misses,
    });
    w.s("\n<h3>Функции сайта</h3><form action=\"/panel/features\" method=\"post\" class=\"box\">");
    c.post();
    w.raw("<table class=\"list\">");
    for (auth.feature_names) |f| {
        // раздел, выключенный флагом -N, в панели не показывается: флаги — потолок
        if (Ctx.sectionOf(f.f)) |sec| if (!c.app.cfg.sec.exists(sec) or (sec == .b and c.app.cfg.sec.booksHidden())) continue;
        w.raw("<tr><td>");
        chk(c, f.key, c.featureOn(f.f), false);
        w.f("</td><td>{s}</td></tr>", .{f.label});
    }
    w.s("</table>\n<input type=\"submit\" value=\"Сохранить\"> <span class=\"muted\">хранится в БД; выключенные разделы скрыты и закрыты для всех, кроме сотрудников и /u/0</span></form>\n<h3>Файлы</h3><form action=\"/panel/files\" method=\"post\" class=\"box\">");
    c.post();
    const fdir = c.db.setting("filesDir") orelse "files";
    w.f("Где искать файлы: <input name=\"dir\" size=\"30\" value=\"{h}\"> <input type=\"submit\" value=\"Сохранить\">\n<div class=\"muted\">Папка внутри папки библиотеки. Отдаются по адресу <code>/files/...</code>.</div></form>\n", .{fdir});
    adminLook(c);
    adminFormats(c);
    adminFed(c);
    adminForums(c);
    w.s("<p class=\"muted\">Вход /u/0 задан флагами запуска (<code>-l</code>, <code>-pwd</code> или <code>-phc</code>) и действует только с этой машины. Он нужен, чтобы настроить сайт: заведите участника и дайте ему права.</p>");
    w.s("\n<h3>Права участников</h3><form action=\"/panel/rights\" method=\"post\">");
    c.post();
    w.s("<table class=\"list\"><tr><th>Участник</th>");
    for (auth.right_names) |r| w.f("<th title=\"{s}\">{s}</th>", .{ r.label, r.key });
    w.s("<th>блок</th></tr>");
    for (c.db.accounts()) |a| {
        const nick = if (c.db.user(a.user)) |u| u.nick else a.login;
        // сотрудник не меняет права себе и другим сотрудникам; право «сотрудник» — только у /u/0
        const locked = !rightsEditable(c, a);
        w.f("<tr><td><a href=\"{U}/u/{d}{E}\">{h}</a><br><span class=\"muted\">{h} · {d}</span><input type=\"hidden\" name=\"acc\" value=\"{h}\"></td>", .{ a.user, nick, a.login, a.user, a.login });
        for (auth.right_names) |r| {
            w.raw("<td align=\"center\">");
            chk(c, std.fmt.allocPrint(c.a, "r_{s}_{s}", .{ a.login, r.key }) catch "", a.rights & r.bit != 0, locked or (r.bit == dbm.rights.staff and !c.isRoot()));
            w.raw("</td>");
        }
        w.raw("<td align=\"center\">");
        chk(c, std.fmt.allocPrint(c.a, "blocked_{s}", .{a.login}) catch "", a.blocked, locked);
        w.raw("</td></tr>");
    }
    w.s("</table>\n<input type=\"submit\" value=\"Сохранить права\"></form>\n<p class=\"muted\">forum — форум; upload — /b/upload; comment — комментарии к книгам; write — черновики, стихи, статьи; quote — цитаты; staff — сотрудник (его форматы загрузки заданы выше). Логин с «@» — гость федерации. Сайтом управляют сотрудники и /u/0; право staff выдаёт и снимает только /u/0, сотрудник не меняет права себе и другим сотрудникам.</p>\n<h3>Встраивание и информеры</h3>\n<table class=\"list\"><tr><th>iframe</th><th>что</th></tr>\n<tr><td><code>/e/b/{book}[?ch=N]</code></td><td>карточка книги / глава</td></tr><tr><td><code>/e/p/{piece}</code></td><td>стихотворение / песня</td></tr>\n<tr><td><code>/e/c/{person}?op=&amp;ed=&amp;sz=</code></td><td>цитата</td></tr><tr><td><code>/e/d/{draft}</code></td><td>черновик / статья</td></tr>\n<tr><td><code>/e/u/{user}</code></td><td>карточка участника</td></tr><tr><td><code>/e/f/{forum}</code></td><td>последние темы форума</td></tr>\n<tr><td><code>/e/stat</code></td><td>статистика сайта</td></tr><tr><td><code>/e/banner</code></td><td>плашка 88×31 / 468×60 (?size=468)</td></tr></table>\n<table class=\"list\"><tr><th>бейдж</th><th>методы</th><th>параметр</th></tr>");
    for (badge.kinds) |k| {
        w.f("<tr><td><code>/x/{s}/</code></td><td>", .{k.name});
        for (k.methods, 0..) |m, i| {
            if (i > 0) w.raw(", ");
            w.f("<code>{s}</code>", .{m});
        }
        w.f("</td><td>{s}</td></tr>", .{if (k.needs_id) "?id=" else T("—")});
    }
    w.s("</table>\n<p class=\"muted\">Формат: <code>/x/{вид}/{метод}[.svg|.png]?id=&amp;label=&amp;color=</code>, без расширения — JSON.</p>");
}

const mode_labels = [_]struct { theme.Mode, []const u8 }{
    .{ .auto, cp.lit("как на устройстве") }, .{ .light, cp.lit("светлая") }, .{ .dark, cp.lit("тёмная") }, .{ .time, cp.lit("по времени суток") },
};

/// Оформление: тема и режим по умолчанию, что из них посетитель выбирает сам
/// и видит ли он настройку оформления.
fn adminLook(c: *Ctx) void {
    const w = &c.w;
    const look = c.app.look;
    const stored = if (c.db.setting("look")) |v| L.field(v, 0) else "";
    w.s("<h3>Оформление</h3><form action=\"/panel/look\" method=\"post\" class=\"box\">");
    c.post();
    w.f("Тема по умолчанию: <select name=\"base\"><option value=\"\"{s}>как во флаге -t ({s})</option>", .{ if (stored.len == 0) " selected" else "", @tagName(c.app.cfg.theme) });
    inline for (@typeInfo(theme.Base).@"enum".fields) |f| {
        w.f("<option value=\"{s}\"{s}>{s}</option>", .{ f.name, if (std.mem.eql(u8, stored, f.name)) " selected" else "", f.name });
    }
    w.s("</select> режим: <select name=\"mode\">");
    for (mode_labels) |m| w.f("<option value=\"{s}\"{s}>{s} — {s}</option>", .{ @tagName(m[0]), if (m[0] == look.mode) " selected" else "", @tagName(m[0]), m[1] });
    w.s("</select><br>\n<label>");
    chk(c, "show", look.show, false);
    w.s(" посетители видят настройку оформления (блок «Оформление», страница <code>/theme</code>, параметр <code>t</code>)</label>\n<table class=\"list\"><tr><th>Темы на выбор</th><th>Режимы на выбор</th></tr><tr><td valign=\"top\">");
    inline for (@typeInfo(theme.Base).@"enum".fields, 0..) |f, i| {
        w.raw("<label>");
        chk(c, "b_" ++ f.name, look.bases & (@as(u4, 1) << i) != 0, false);
        w.f(" {s}</label><br>", .{f.name});
    }
    w.raw("</td><td valign=\"top\">");
    for (mode_labels, 0..) |m, i| {
        w.raw("<label>");
        chk(c, std.fmt.allocPrint(c.a, "m_{s}", .{@tagName(m[0])}) catch "", look.modes & (@as(u4, 1) << @intCast(i)) != 0, false);
        w.f(" {s} — {s}</label><br>", .{ @tagName(m[0]), m[1] });
    }
    w.s("</td></tr></table>\n<input type=\"submit\" value=\"Сохранить\"> <span class=\"muted\">тема и режим по умолчанию доступны всегда; без галочки «видят» у всех посетителей оформление одно</span></form>\n");
}

fn lookPost(c: *Ctx) void {
    const base_raw = c.form.get("base");
    const base: []const u8 = if (theme.baseOf(base_raw)) |b| @tagName(b) else "";
    const mode = std.meta.stringToEnum(theme.Mode, c.form.get("mode")) orelse .auto;
    var bases: u8 = 0;
    inline for (@typeInfo(theme.Base).@"enum".fields, 0..) |f, i| {
        if (c.form.on("b_" ++ f.name)) bases |= 1 << i;
    }
    var modes: u8 = 0;
    inline for (@typeInfo(theme.Mode).@"enum".fields, 0..) |f, i| {
        if (c.form.on("m_" ++ f.name)) modes |= 1 << i;
    }
    c.db.setSetting("look", L.rec(c.a, .{ base, @tagName(mode), bases, modes, c.form.on("show") }));
    c.app.loadSettings(c.a, true);
    c.setTm();
    panelPage(c, T("Оформление сохранено."));
}

const format_labels = [_]struct { import.Kind, []const u8 }{
    .{ .txt, cp.lit("txt и текст из формы") }, .{ .fb2, "fb2" }, .{ .epub, "epub" }, .{ .pdf, cp.lit("pdf (экспериментально, только с текстовым слоем)") }, .{ .djvu, cp.lit("djvu (экспериментально, только с текстовым слоем)") },
};

/// Форматы загрузки книг: отдельно сотрудникам (право staff) и прочим участникам.
fn adminFormats(c: *Ctx) void {
    const w = &c.w;
    const fm = c.app.formats;
    w.s("<h3>Форматы загрузки книг</h3><form action=\"/panel/formats\" method=\"post\" class=\"box\">");
    c.post();
    w.s("<table class=\"list\"><tr><th>Формат</th><th>сотрудники</th><th>прочие участники</th></tr>");
    const launch = c.app.cfg.launchFormats();
    for (format_labels) |f| {
        if ((f[0] == .pdf and !import.has_pdf) or (f[0] == .djvu and !import.has_djvu)) continue;
        const bit = @as(u8, 1) << @intFromEnum(f[0]);
        w.f("<tr><td>{s}", .{f[1]});
        if (launch & bit == 0) w.f("<br><span class=\"muted\">выключено: сайт запущен без -{s}</span>", .{@tagName(f[0])});
        w.raw("</td><td align=\"center\">");
        chk(c, std.fmt.allocPrint(c.a, "fs_{s}", .{@tagName(f[0])}) catch "", fm.staff & bit != 0, false);
        w.raw("</td><td align=\"center\">");
        chk(c, std.fmt.allocPrint(c.a, "fu_{s}", .{@tagName(f[0])}) catch "", fm.users & bit != 0, false);
        w.raw("</td></tr>");
    }
    w.s("</table>\n<input type=\"submit\" value=\"Сохранить\"> <span class=\"muted\">сотрудник — участник с правом <code>staff</code> (таблица прав ниже); выкладывать книги вообще разрешает право <code>upload</code>; /u/0 выкладывает любые</span></form>\n");
}

fn formatsPost(c: *Ctx) void {
    var staff: u8 = 0;
    var users: u8 = 0;
    inline for (@typeInfo(import.Kind).@"enum".fields, 0..) |f, i| {
        if (c.form.on("fs_" ++ f.name)) staff |= 1 << i;
        if (c.form.on("fu_" ++ f.name)) users |= 1 << i;
    }
    c.db.setSetting("import", L.rec(c.a, .{ staff, users }));
    c.app.loadSettings(c.a, true);
    panelPage(c, T("Форматы загрузки сохранены."));
}

fn tri(c: *Ctx, name: []const u8, v: ?bool) void {
    c.w.f("<select name=\"{h}\"><option value=\"\"{s}>по умолчанию</option><option value=\"1\"{s}>да</option><option value=\"0\"{s}>нет</option></select>", .{
        name, if (v == null) " selected" else "", if (v == true) " selected" else "", if (v == false) " selected" else "",
    });
}

fn triOf(s: []const u8) ?bool {
    return if (std.mem.eql(u8, s, "1")) true else if (std.mem.eql(u8, s, "0")) false else null;
}

const fed_rows = 500;

/// Федерация: список сайтов и кому что разрешено (файл FEDIVERSE.csv).
fn adminFed(c: *Ctx) void {
    const w = &c.w;
    const f = &c.app.fed;
    w.s("<h3>Федерация</h3>");
    if (!f.on()) return w.s("<p class=\"muted\">Выключена. Включается флагом <code>-fed</code> при запуске.</p>\n");
    w.f("<p class=\"muted\">{s} Список: {s}{h}{s}. Сайтов: {d}. <a href=\"{U}/fed{E}\">Страница федерации</a></p>", .{
        switch (f.mode) {
            .open => T("Новые сайты записываются сами."),
            .closed => T("Только названные сайты (<code>-fed -</code>)."),
            else => T("Только сайты из флага <code>-fed</code>."),
        },
        if (f.writable()) "<code>" else "",
        if (f.writable()) (cp.encodeAlloc(c.a, f.path) catch "") else T("задан в командной строке, здесь не правится"),
        if (f.writable()) "</code>" else "",
        f.entries.items.len,
    });
    const edit = f.writable();
    if (edit) {
        w.raw("<form action=\"/panel/fed\" method=\"post\">");
        c.post();
    }
    w.s("<table class=\"list\"><tr><th>Сайт</th><th title=\"authInsideService\">его участники входят сюда</th><th title=\"authOutsideService\">наши входят туда</th></tr>");
    if (edit) {
        w.s("<tr><td><i>по умолчанию</i> <span class=\"muted\">(строка localhost)</span></td><td align=\"center\">");
        chk(c, "def_in", f.def_in orelse false, false);
        w.raw("</td><td align=\"center\">");
        chk(c, "def_out", f.def_out orelse false, false);
        w.raw("</td></tr>");
    }
    for (f.entries.items, 0..) |e, i| {
        if (i == fed_rows) break;
        w.f("<tr><td>{s}{h}", .{ switch (e.scheme) {
            .auto => "",
            .http => "http://",
            .https => "https://",
        }, e.domain });
        if (edit) {
            w.f("<input type=\"hidden\" name=\"fd\" value=\"{h}\"></td><td align=\"center\">", .{e.domain});
            tri(c, std.fmt.allocPrint(c.a, "in_{s}", .{e.domain}) catch "", e.in);
            w.raw("</td><td align=\"center\">");
            tri(c, std.fmt.allocPrint(c.a, "out_{s}", .{e.domain}) catch "", e.out);
            w.raw("</td></tr>");
        } else w.f("</td><td align=\"center\">{s}</td><td align=\"center\">{s}</td></tr>", .{ if (f.allowIn(e)) T("да") else T("нет"), if (f.allowOut(e)) T("да") else T("нет") });
    }
    w.raw("</table>");
    if (f.entries.items.len > fed_rows) w.f("<p class=\"muted\">Показаны первые {d}; остальные правятся в файле.</p>", .{fed_rows});
    if (edit) {
        if (f.mode == .open or f.mode == .closed) w.s("\nДобавить сайт: <input name=\"new\" size=\"30\"> ");
        w.s("<input type=\"submit\" value=\"Сохранить федерацию\"> <span class=\"muted\">файл переписывается целиком; его можно править и руками — сервер перечитает сам</span></form>\n");
    }
}

fn fedPost(c: *Ctx) void {
    const f = &c.app.fed;
    if (!f.on() or !f.writable()) return panelPage(c, T("Список федерации здесь не правится."));
    f.def_in = c.form.on("def_in");
    f.def_out = c.form.on("def_out");
    for (c.form.fields) |fld| {
        if (!std.mem.eql(u8, fld.name, "fd")) continue;
        const e = f.find(std.mem.trim(u8, fld.value, " ")) orelse continue;
        e.in = triOf(c.form.get(std.fmt.allocPrint(c.a, "in_{s}", .{e.domain}) catch ""));
        e.out = triOf(c.form.get(std.fmt.allocPrint(c.a, "out_{s}", .{e.domain}) catch ""));
    }
    const new = c.form.get("new");
    if (new.len > 0) {
        var nb: [fed.max_domain]u8 = undefined;
        const name = fed.normalize(&nb, new) orelse return panelPage(c, T("Новый сайт: это не имя сайта."));
        if (std.mem.eql(u8, name.domain, "localhost")) return panelPage(c, T("localhost — это строка умолчаний, она уже в таблице."));
        if (f.find(name.domain) == null) {
            const mode = f.mode;
            f.mode = .open; // администратор добавляет сайт и в закрытый список
            defer f.mode = mode;
            _ = f.add(c.app.root, name) catch return panelPage(c, T("Новый сайт не записан."));
        }
    }
    f.save(c.app.root) catch return panelPage(c, T("Файл списка федерации не записан."));
    panelPage(c, T("Федерация сохранена."));
}

/// POST /panel/{что}
pub fn panelPost(c: *Ctx, what: []const u8) void {
    const me = c.me.?;
    const eq = std.mem.eql;
    if (eq(u8, what, "profile")) {
        var u = c.db.user(me.user) orelse dbm.User{ .id = me.user, .nick = me.login, .joined = c.today(), .about = "", .login = me.login };
        const guest = dbm.Db.external(me.login);
        const nick = c.form.get("nick");
        if (nick.len > 0 and !guest) u.nick = nick[0..@min(nick.len, 40)];
        const about = c.form.get("about");
        u.about = about[0..@min(about.len, 1000)];
        c.db.putUser(u);
        const pass = if (guest) "" else c.form.raw("pass");
        if (pass.len > 0) {
            if (pass.len < 4) return panelPage(c, T("Пароль слишком короткий."));
            if (pass.len > 200) return panelPage(c, T("Пароль слишком длинный."));
            const hash = auth.hashPassword(c.a, pass);
            if (c.isRoot()) {
                return panelPage(c, T("Пароль /u/0 задаётся флагом запуска -pwd или -phc."));
            } else {
                var acc = me;
                acc.hash = hash;
                c.db.putAccount(acc);
            }
        }
        return panelPage(c, T("Профиль сохранён."));
    }
    if (eq(u8, what, "books")) {
        for (c.form.fields) |f| {
            if (!eq(u8, f.name, "book")) continue;
            const id = std.fmt.parseInt(i32, std.mem.trim(u8, f.value, " "), 10) catch continue;
            const b = c.db.s.book(id) orelse continue;
            if (!mine(c, b)) continue;
            var st = c.db.bookStat(id);
            st.embed = c.form.on(std.fmt.allocPrint(c.a, "embed{d}", .{id}) catch "");
            c.db.putBookStat(id, st, false);
        }
        return panelPage(c, T("Настройки встраивания сохранены."));
    }
    const known = eq(u8, what, "features") or eq(u8, what, "rights") or eq(u8, what, "files") or eq(u8, what, "look") or eq(u8, what, "formats") or eq(u8, what, "fed") or eq(u8, what, "forums");
    if (!c.isModerator()) return panelPage(c, T("Сайтом управляют сотрудники и /u/0."));
    if (!known) return c.notFound();
    if (eq(u8, what, "features")) {
        var bits: u16 = 0;
        for (auth.feature_names) |f| {
            if (c.form.on(f.key)) bits |= auth.bit(f.f);
        }
        var nb: [8]u8 = undefined;
        c.db.setSetting("features", std.fmt.bufPrint(&nb, "{d}", .{bits}) catch unreachable);
        c.app.features = bits;
        c.app.features_at = c.app.ledger.changes;
        return panelPage(c, T("Функции сайта сохранены."));
    }
    if (eq(u8, what, "rights")) {
        for (c.form.fields) |f| {
            if (!eq(u8, f.name, "acc")) continue;
            var acc = c.db.account(std.mem.trim(u8, f.value, " ")) orelse continue;
            if (!rightsEditable(c, acc)) continue;
            const staff_was = acc.rights & dbm.rights.staff;
            acc.rights = 0;
            for (auth.right_names) |r| {
                if (c.form.on(std.fmt.allocPrint(c.a, "r_{s}_{s}", .{ acc.login, r.key }) catch "")) acc.rights |= r.bit;
            }
            // право «сотрудник» меняет только /u/0
            if (!c.isRoot()) acc.rights = (acc.rights & ~dbm.rights.staff) | staff_was;
            acc.blocked = c.form.on(std.fmt.allocPrint(c.a, "blocked_{s}", .{acc.login}) catch "");
            c.db.putAccount(acc);
        }
        return panelPage(c, T("Права сохранены."));
    }
    if (eq(u8, what, "look")) return lookPost(c);
    if (eq(u8, what, "formats")) return formatsPost(c);
    if (eq(u8, what, "fed")) return fedPost(c);
    if (eq(u8, what, "forums")) return forumsPost(c);
    if (eq(u8, what, "files")) {
        const dir = c.form.get("dir");
        const bad = dir.len > 200 or std.mem.indexOf(u8, dir, "..") != null or std.mem.indexOfAny(u8, dir, ":*?\"<>|") != null or (dir.len > 0 and (dir[0] == '/' or dir[0] == '\\'));
        if (bad) return panelPage(c, T("Папка файлов должна лежать внутри папки библиотеки."));
        c.db.setSetting("filesDir", if (dir.len > 0) dir else "files");
        return panelPage(c, T("Папка файлов сохранена."));
    }
    c.notFound();
}

/// Сроки жизни нитей на выбор при заведении доски, в минутах.
const board_ttls = [_]struct { min: i64, label: []const u8 }{
    .{ .min = 60, .label = "1 ч" },
    .{ .min = 360, .label = "6 ч" },
    .{ .min = 1440, .label = "24 ч" },
    .{ .min = 10080, .label = "7 дней" },
};

/// Форумы и доски: список и заведение новых. Других способов завести их нет:
/// в программе нет ни одного форума и ни одной доски, сайт начинается пустым.
fn adminForums(c: *Ctx) void {
    const w = &c.w;
    if (!c.app.cfg.sec.exists(.f)) return;
    w.s("\n<h3>Форумы и доски</h3>");
    const fs = c.db.forums();
    if (fs.len == 0) w.s("<p class=\"muted\">Форумов пока нет.</p>") else {
        w.s("<table class=\"list\"><tr><th>Форум</th><th>Описание</th></tr>");
        for (fs) |f| w.f("<tr><td><a href=\"{U}/f/{d}{E}\">/f/{d}</a> {h}</td><td>{h}</td></tr>", .{ f.id, f.id, f.title, f.about });
        w.raw("</table>");
    }
    w.raw("<form action=\"/panel/forums\" method=\"post\" class=\"box\">");
    c.post();
    w.s("<input type=\"hidden\" name=\"kind\" value=\"forum\">Новый форум: название <input name=\"title\" size=\"24\"> описание <input name=\"about\" size=\"36\"> <input type=\"submit\" value=\"Завести форум\"></form>\n");
    const bs = c.db.boards();
    if (bs.len == 0) w.s("<p class=\"muted\">Досок пока нет.</p>") else {
        w.s("<table class=\"list\"><tr><th>Доска</th><th>Срок жизни нити</th></tr>");
        for (bs) |b| w.f("<tr><td><a href=\"{U}/f/{s}{E}\">/{s}/</a> {h}</td><td>{d} мин</td></tr>", .{ b.id, b.id, b.title, b.ttl_min });
        w.raw("</table>");
    }
    w.raw("<form action=\"/panel/forums\" method=\"post\" class=\"box\">");
    c.post();
    w.s("<input type=\"hidden\" name=\"kind\" value=\"board\">Новая доска: адрес /f/<input name=\"id\" size=\"8\" maxlength=\"8\"> название <input name=\"title\" size=\"24\"> нить живёт <select name=\"ttl\">");
    for (board_ttls) |t| w.f("<option value=\"{d}\">{s}</option>", .{ t.min, t.label });
    w.s("</select> <input type=\"submit\" value=\"Завести доску\">\n<div class=\"muted\">Адрес доски — от 1 до 8 латинских букв и цифр, не одни цифры: /f/1 — это форум.</div></form>\n");
}

fn forumsPost(c: *Ctx) void {
    const eq = std.mem.eql;
    const title = std.mem.trim(u8, c.form.get("title"), " ");
    if (title.len == 0) return panelPage(c, T("Укажите название."));
    const t = title[0..@min(title.len, 100)];
    if (eq(u8, c.form.get("kind"), "forum")) {
        var next: i32 = 1;
        for (c.db.forums()) |f| next = @max(next, f.id + 1);
        const about = std.mem.trim(u8, c.form.get("about"), " ");
        c.app.ledger.put(L.key(c.a, "F", .{next}), L.rec(c.a, .{ t, about[0..@min(about.len, 300)] }));
        return panelPage(c, T("Форум заведён."));
    }
    const raw = std.mem.trim(u8, c.form.get("id"), " ");
    const id = std.ascii.allocLowerString(c.a, raw) catch return panelPage(c, T("Не хватает памяти."));
    var digits = true;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) return panelPage(c, T("Адрес доски — от 1 до 8 латинских букв и цифр."));
        if (!std.ascii.isDigit(ch)) digits = false;
    }
    if (id.len < 1 or id.len > 8 or digits) return panelPage(c, T("Адрес доски — от 1 до 8 латинских букв и цифр."));
    if (c.db.board(id) != null) return panelPage(c, T("Такая доска уже есть."));
    var ttl: i64 = 0;
    const want = std.fmt.parseInt(i64, c.form.get("ttl"), 10) catch 0;
    for (board_ttls) |x| if (x.min == want) {
        ttl = want;
    };
    if (ttl == 0) return panelPage(c, T("Неизвестный срок жизни нити."));
    c.app.ledger.put(L.key(c.a, "B", .{id}), L.rec(c.a, .{ t, ttl }));
    return panelPage(c, T("Доска заведена."));
}
