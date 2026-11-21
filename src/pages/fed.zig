//! Федерация: /fed (страница), /fed/out (перейти на другой сайт), /fed/from
//! (позвать гостя с другого сайта), /fed/in (принять гостя), /fed/verify
//! (ответ другому сайту о билете). Правила и список сайтов — fed.zig.

const std = @import("std");
const cp = @import("../cp1251.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const auth = @import("../auth.zig");
const fed = @import("../fed.zig");
const client = @import("../net/client.zig");
const W = @import("../out.zig").W;
const Ctx = @import("../app.zig").Ctx;
const account = @import("account.zig");

const T = cp.text;

fn join(c: *Ctx, parts: []const []const u8) []const u8 {
    return std.mem.concat(c.a, u8, parts) catch "";
}

/// Имя этого сайта, каким его назвал браузер.
fn self(c: *Ctx, buf: *[fed.max_domain]u8) ?[]const u8 {
    return (fed.normalize(buf, c.req.host) orelse return null).domain;
}

fn ticketKey(c: *Ctx, ticket: []const u8) []const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ticket, &h, .{});
    return std.fmt.allocPrint(c.a, "G{s}", .{std.fmt.fmtSliceHexLower(h[0..16])}) catch "G";
}

/// Адрес сайта федерации: «https://example.com».
fn origin(w: *W, scheme: fed.Scheme, domain: []const u8) void {
    w.raw(if (fed.useHttps(scheme, domain)) "https://" else "http://");
    w.raw(domain);
}

/// Вошедший здесь по паролю участник, не администратор: он может ходить на другие сайты.
fn traveller(c: *const Ctx) bool {
    const me = c.me orelse return false;
    return me.user != 0 and !dbm.Db.external(me.login);
}

pub fn page(c: *Ctx, msg: []const u8) void {
    const w = &c.w;
    const f = &c.app.fed;
    if (!f.on()) return c.notFound();
    c.no_cache = true;
    w.s("<h2>Федерация</h2>");
    c.msgBox(msg);
    w.s("\n<p>Сайты федерации доверяют друг другу вход: участник одного сайта заходит на другой под своим именем, без пароля и регистрации.</p>");

    if (c.me) |me| if (dbm.Db.external(me.login)) {
        const at = std.mem.indexOfScalar(u8, me.login, '@').?;
        w.f("\n<div class=\"box\">Вы вошли с сайта <b>{h}</b> как <b>{h}</b>. Пароля здесь у вас нет: вход держится на токене, который гаснет через 45 минут бездействия или с закрытием браузера. <a href=\"{U}/logout{E}\">Выйти</a></div>", .{ me.login[at + 1 ..], c.db.name(me.user) });
    };

    // отсюда — на другой сайт
    w.s("\n<h3>Перейти на другой сайт</h3>");
    const to = c.q("to");
    if (c.me == null) {
        w.f("<p class=\"box\">Чтобы перейти на другой сайт под своим именем, сначала <a href=\"{U}/signin?back={q}{E}\">войдите</a> здесь.</p>", .{c.here()});
    } else if (!traveller(c)) {
        w.s("<p class=\"muted\">Гости с других сайтов и администратор /u/0 дальше по федерации не ходят.</p>");
    } else {
        var n: usize = 0;
        for (f.entries.items) |e| {
            if (!f.allowOut(e)) continue;
            if (n == 0) w.raw("<table class=\"list\">");
            n += 1;
            w.f("<tr><td><b>{h}</b></td><td><form action=\"/fed/out\" method=\"post\" style=\"margin:0\">", .{e.domain});
            c.post();
            w.f("<input type=\"hidden\" name=\"domain\" value=\"{h}\"><input type=\"submit\" value=\"Перейти\"></form></td></tr>", .{e.domain});
        }
        if (n > 0) w.raw("</table>") else w.s("<p class=\"muted\">Сайтов, куда разрешён переход, пока нет.</p>");
        if (f.mode == .open) {
            w.raw("\n<form action=\"/fed/out\" method=\"post\" class=\"box\">");
            c.post();
            w.f("Другой сайт: <input name=\"domain\" size=\"30\" value=\"{h}\"> <input type=\"submit\" value=\"Перейти\">\n<div class=\"muted\">Новый сайт запишется в список федерации; перейти получится, если администратор разрешил переход на новые сайты.</div></form>", .{to});
        }
    }

    // с другого сайта — сюда
    w.s("\n<h3>Войти сюда с другого сайта</h3>");
    var n: usize = 0;
    for (f.entries.items) |e| {
        if (!f.allowIn(e)) continue;
        if (n == 0) w.raw("<ul>");
        n += 1;
        w.f("<li><a href=\"/fed/from?domain={q}\">{h}</a></li>", .{ e.domain, e.domain });
    }
    if (n > 0) w.raw("</ul>") else w.s("<p class=\"muted\">Сайтов, с которых разрешён вход, пока нет.</p>");
    if (f.mode == .open) {
        w.raw("\n<form action=\"/fed/from\" method=\"get\" class=\"box\">");
        w.s("Другой сайт: <input name=\"domain\" size=\"30\"> <input type=\"submit\" value=\"Войти оттуда\">\n<div class=\"muted\">Откроется страница федерации того сайта: войдите там и нажмите «Перейти».</div></form>");
    }
    c.page(.{ .title = T("Федерация"), .crumbs = &.{.{ .text = T("Федерация") }} });
}

fn refuse(c: *Ctx, status: u16, parts: []const []const u8) void {
    c.status = status;
    page(c, join(c, parts));
}

/// 303 на другой сайт (свои `m` и `t` туда не протягиваются).
fn leave(c: *Ctx) void {
    c.reply.status = 303;
    c.reply.ctype = "text/plain; charset=utf-8";
    c.reply.body = "";
    c.reply.header("Location: {s}", .{c.out.out()});
}

/// GET /fed/from?domain=X — на страницу федерации сайта X, чтобы прийти оттуда.
pub fn fromGet(c: *Ctx) void {
    const f = &c.app.fed;
    if (!f.on()) return c.notFound();
    var nb: [fed.max_domain]u8 = undefined;
    var sb: [fed.max_domain]u8 = undefined;
    const name = fed.normalize(&nb, c.q("domain")) orelse return refuse(c, 400, &.{T("Это не имя сайта.")});
    const me = self(c, &sb) orelse return refuse(c, 400, &.{T("Сайт не знает своего имени: запрос пришёл без заголовка Host.")});
    if (std.mem.eql(u8, name.domain, me)) return refuse(c, 400, &.{T("Это и есть этот сайт.")});
    const e = f.find(name.domain);
    if (e == null and f.mode != .open) return refuse(c, 403, &.{ T("Сайт "), name.domain, T(" не входит в федерацию этого сайта.") });
    c.out.n = 0;
    origin(&c.out, if (e) |x| x.scheme else name.scheme, name.domain);
    c.out.raw("/fed?to=");
    c.out.urlenc(me);
    leave(c);
}

/// POST /fed/out — билет и переход на другой сайт.
pub fn outPost(c: *Ctx) void {
    const f = &c.app.fed;
    if (!f.on()) return c.notFound();
    const me = c.me orelse return c.redirect("/signin?back=/fed", .{});
    if (!traveller(c)) return refuse(c, 403, &.{T("Гости с других сайтов и администратор /u/0 дальше по федерации не ходят.")});
    var nb: [fed.max_domain]u8 = undefined;
    var sb: [fed.max_domain]u8 = undefined;
    const name = fed.normalize(&nb, c.form.get("domain")) orelse return refuse(c, 400, &.{T("Это не имя сайта.")});
    const here = self(c, &sb) orelse return refuse(c, 400, &.{T("Сайт не знает своего имени: запрос пришёл без заголовка Host.")});
    if (std.mem.eql(u8, name.domain, here) or std.mem.eql(u8, name.domain, "localhost")) return refuse(c, 400, &.{T("Это и есть этот сайт.")});
    var e = f.find(name.domain);
    if (e == null) {
        if (f.mode != .open) return refuse(c, 403, &.{ T("Сайт "), name.domain, T(" не входит в федерацию этого сайта.") });
        e = f.add(c.app.root, name) catch return refuse(c, 500, &.{T("Сайт не записан в список федерации.")});
    }
    if (!f.allowOut(e.?.*)) return refuse(c, 403, &.{ T("Переход на "), name.domain, T(" администратор пока не разрешил.") });

    // просроченные билеты заодно убираются
    var stale = std.ArrayList([]const u8).init(c.a);
    var it = c.db.l.scan(c.a, "G");
    while (it.next()) |x| {
        if (L.fieldInt(x.val, 2) < c.app.now) stale.append(c.a.dupe(u8, x.key) catch continue) catch break;
    }
    for (stale.items) |k| c.db.l.del(k);

    var ticket: [32]u8 = undefined;
    auth.randomToken(&ticket);
    c.db.l.putQuiet(ticketKey(c, &ticket), L.rec(c.a, .{ me.user, name.domain, c.app.now + fed.ticket_ttl_s }));
    c.out.n = 0;
    origin(&c.out, e.?.scheme, name.domain);
    c.out.raw("/fed/in?from=");
    c.out.urlenc(here);
    c.out.raw("&ticket=");
    c.out.raw(&ticket);
    leave(c);
}

/// GET /fed/verify?ticket=…&for=B — спрашивает сайт B, к которому пришёл наш
/// участник. Билет одноразовый: гаснет при первом же вопросе.
pub fn verifyGet(c: *Ctx) void {
    const f = &c.app.fed;
    if (!f.on()) return c.notFound();
    const w = &c.out;
    w.n = 0;
    w.raw("clipper-fed 1\n");
    const why: []const u8 = blk: {
        const ticket = c.q("ticket");
        if (!auth.validToken(ticket)) break :blk "ticket";
        const key = ticketKey(c, ticket);
        const v = c.db.l.get(c.a, key) orelse break :blk "ticket";
        const uid = std.math.cast(i32, L.fieldInt(v, 0)) orelse 0;
        const target = c.a.dupe(u8, L.field(v, 1)) catch "";
        const expires = L.fieldInt(v, 2);
        c.db.l.del(key);
        if (expires < c.app.now) break :blk "expired";
        var nb: [fed.max_domain]u8 = undefined;
        const asked = fed.normalize(&nb, c.q("for")) orelse break :blk "for";
        if (!std.mem.eql(u8, asked.domain, target)) break :blk "for";
        const e = f.find(target) orelse break :blk "closed";
        if (!f.allowOut(e.*)) break :blk "closed";
        const u = c.db.user(uid) orelse break :blk "user";
        const acc = c.db.account(u.login) orelse break :blk "user";
        if (acc.blocked or dbm.Db.external(acc.login)) break :blk "user";
        w.f("id={d}\nnick=", .{uid});
        w.urlenc(cp.toUtf8Alloc(c.a, u.nick) catch "");
        w.byte('\n');
        return c.send("text/plain; charset=utf-8", w.out());
    };
    w.f("error={s}\n", .{why});
    c.status = 403;
    c.send("text/plain; charset=utf-8", w.out());
}

const Guest = struct { id: []const u8, nick: []const u8 };

/// Ответ /fed/verify: «clipper-fed 1», дальше строки имя=значение.
fn parseVerify(c: *Ctx, body: []const u8) ?Guest {
    var lines = std.mem.splitScalar(u8, body, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse "", " \r"), "clipper-fed 1")) return null;
    var g = Guest{ .id = "", .nick = "" };
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "error=")) return null;
        if (std.mem.startsWith(u8, line, "id=")) g.id = line[3..];
        if (std.mem.startsWith(u8, line, "nick=")) {
            const utf8 = @import("../http.zig").urlDecode(c.a, line[5..]) catch return null;
            g.nick = @import("../http.zig").cleanText(c.a, utf8) catch return null;
        }
    }
    // номер участника на его сайте: целое со знаком
    if (g.id.len == 0 or g.id.len > 11) return null;
    for (g.id, 0..) |ch, i| if (!(std.ascii.isDigit(ch) or (i == 0 and ch == '-' and g.id.len > 1))) return null;
    for (g.nick) |ch| if (ch == '\n') return null;
    return g;
}

/// GET /fed/in?from=A&ticket=… — участник сайта A пришёл сюда.
pub fn inGet(c: *Ctx) void {
    const f = &c.app.fed;
    if (!f.on()) return c.notFound();
    var nb: [fed.max_domain]u8 = undefined;
    var sb: [fed.max_domain]u8 = undefined;
    const ticket = c.q("ticket");
    const name = fed.normalize(&nb, c.q("from")) orelse return refuse(c, 400, &.{T("Запрос федерации не разобран.")});
    if (!auth.validToken(ticket)) return refuse(c, 400, &.{T("Запрос федерации не разобран.")});
    const here = self(c, &sb) orelse return refuse(c, 400, &.{T("Сайт не знает своего имени: запрос пришёл без заголовка Host.")});
    if (std.mem.eql(u8, name.domain, here) or std.mem.eql(u8, name.domain, "localhost")) return refuse(c, 400, &.{T("Это и есть этот сайт.")});

    const known = f.find(name.domain);
    if (known == null and f.mode != .open) return refuse(c, 403, &.{ T("Сайт "), name.domain, T(" не входит в федерацию этого сайта.") });
    if (known) |e| if (!f.allowIn(e.*)) return refuse(c, 403, &.{ T("Вход с сайта "), name.domain, T(" администратор пока не разрешил.") });
    if (known == null and f.entries.items.len >= fed.max_entries) return refuse(c, 403, &.{T("Список федерации полон.")});

    // настоящий ли билет, знает только сайт, который его выписал
    const scheme = if (known) |e| e.scheme else name.scheme;
    const path = join(c, &.{ "/fed/verify?ticket=", ticket, "&for=", here });
    const res = client.get(c.a, fed.useHttps(scheme, name.domain), name.domain, path, known == null) catch |err| return refuse(c, 502, &.{ T("Сайт "), name.domain, switch (err) {
        error.NoTls => T(" работает по https, а эта сборка сервера (для Windows XP) проверять https не умеет."),
        error.Tls => T(" не прошёл проверку сертификата https."),
        error.Private => T(" ведёт во внутреннюю сеть; такой сайт должен быть назван в списке федерации."),
        error.Timeout => T(" не ответил вовремя."),
        error.Resolve, error.BadAddress => T(" не найден."),
        else => T(" не отвечает."),
    } });
    const guest = (if (res.status == 200) parseVerify(c, res.body) else null) orelse
        return refuse(c, 403, &.{ T("Сайт "), name.domain, T(" не подтвердил вход: билет уже использован, просрочен или выписан не сюда.") });

    if (known == null) {
        // новый сайт: записывается всегда, пускает — если так велят умолчания
        _ = f.add(c.app.root, name) catch return refuse(c, 500, &.{T("Сайт не записан в список федерации.")});
        if (!f.allowIn(null)) return refuse(c, 403, &.{ T("Сайт "), name.domain, T(" записан в список федерации; вход с него откроется, когда разрешит администратор.") });
    }

    const login = join(c, &.{ guest.id, "@", name.domain });
    const shown = guest.nick[0..@min(guest.nick.len, 40)];
    const nick = join(c, &.{ if (shown.len > 0) shown else guest.id, "@", name.domain });
    if (c.db.account(login)) |acc| {
        if (acc.blocked) return refuse(c, 403, &.{T("Этому гостю вход закрыт администратором.")});
        if (c.db.user(acc.user)) |u| if (!std.mem.eql(u8, u.nick, nick)) {
            var fresh = u;
            fresh.nick = nick;
            c.db.putUser(fresh);
        };
    } else {
        var id: i32 = undefined;
        while (true) {
            id = c.db.nextId("user", 1001, 1);
            if (!c.db.isUser(id) and c.db.person(id) == null) break;
        }
        c.db.putUser(.{ .id = id, .nick = nick, .joined = c.today(), .about = join(c, &.{ T("Гость с сайта "), name.domain, T(" (федерация).") }), .login = login });
        c.db.putAccount(.{ .login = login, .user = id, .hash = "", .rights = dbm.rights.default, .blocked = false });
    }
    account.setSid(c, auth.startSession(c.db, login, c.req.user_agent, c.ip, c.app.now));
    c.redirect("/", .{});
}
