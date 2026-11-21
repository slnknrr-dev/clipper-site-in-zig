//! Профили (BACKLOG_RU.md §21): фото и закреплённые обсуждения у людей сайта (/c/N,
//! N > 0) и у участников (/u/N); правка — /c/N/edit и /u/N/edit.
//!
//! Профиль человека правят сотрудники, /u/0 и участники, привязанные к нему;
//! профиль участника — он сам, сотрудники и /u/0. Фото обрабатывается как
//! картинки книг (свой разбор, JPEG или PNG, хранилище img/b) и показывается в
//! месте 240×320 по центру; закреплённые — форумы и доски сайта.

const std = @import("std");
const cp = @import("../cp1251.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const snapshot = @import("../snapshot.zig");
const imgstore = @import("../imgstore.zig");
const Ctx = @import("../app.zig").Ctx;
const h = @import("h.zig");

const T = cp.text;
pub const photo_w = 240;
pub const photo_h = 320;

pub fn canEditPerson(c: *const Ctx, pid: i32) bool {
    const me = c.me orelse return false;
    if (c.isModerator()) return true;
    for (c.db.authorsOf(me.user)) |p| if (p == pid) return true;
    return false;
}

pub fn canEditUser(c: *const Ctx, uid: i32) bool {
    const me = c.me orelse return false;
    if (uid == 0) return me.user == 0;
    return me.user == uid or c.isModerator();
}

/// Фото и закреплённые обсуждения (на странице человека или участника).
pub fn show(c: *Ctx, id: i32, edit_href: ?[]const u8) void {
    const w = &c.w;
    const pr = c.db.profile(id);
    if (pr.hash != 0) {
        const im = snapshot.Image{ .hash = pr.hash, .w = pr.w, .h = pr.h, .kind = pr.kind };
        w.raw("<div style=\"max-width:240px\">");
        h.figure(c, &im, photo_w, photo_h);
        w.raw("</div>");
    }
    if (pr.pins.len > 0) {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, pr.pins, ',');
        while (it.next()) |pin| {
            if (pin.len < 2) continue;
            const title: []const u8 = if (pin[0] == 'f') blk: {
                const fid = std.fmt.parseInt(i32, pin[1..], 10) catch continue;
                if (!c.featureOpen(.forum)) continue;
                const f = c.db.forum(fid) orelse continue;
                break :blk f.title;
            } else if (pin[0] == 'b') blk: {
                if (!c.featureOpen(.boards)) continue;
                const b = c.db.board(pin[1..]) orelse continue;
                break :blk b.title;
            } else continue;
            if (n == 0) w.s("<p>Обсуждения: ") else w.raw(" · ");
            n += 1;
            w.f("<a href=\"{U}/f/{s}{E}\">{h}</a>", .{ pin[1..], title });
        }
        if (n > 0) w.raw("</p>\n");
    }
    if (edit_href) |e| w.f("<p><a href=\"{U}{s}{E}\">Править профиль</a></p>\n", .{e});
}

fn pinsForm(c: *Ctx, cur: []const u8) void {
    const w = &c.w;
    const has = struct {
        fn f(list: []const u8, key: []const u8) bool {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |x| if (std.mem.eql(u8, x, key)) return true;
            return false;
        }
    }.f;
    w.s("<tr><td valign=\"top\">Обсуждения</td><td>");
    var n: usize = 0;
    for (c.db.forums()) |f| {
        const key = std.fmt.allocPrint(c.a, "f{d}", .{f.id}) catch continue;
        w.f("<label><input type=\"checkbox\" name=\"pin\" value=\"{s}\"{s}> форум «{h}»</label><br>", .{ key, if (has(cur, key)) " checked" else "", f.title });
        n += 1;
    }
    for (c.db.boards()) |b| {
        const key = std.fmt.allocPrint(c.a, "b{s}", .{b.id}) catch continue;
        w.f("<label><input type=\"checkbox\" name=\"pin\" value=\"{h}\"{s}> доска /f/{h} «{h}»</label><br>", .{ key, if (has(cur, key)) " checked" else "", b.id, b.title });
        n += 1;
    }
    if (n == 0) w.s("<span class=\"muted\">форумов и досок пока нет</span>");
    w.s("</td></tr>\n");
}

fn photoForm(c: *Ctx, pr: dbm.Profile) void {
    const w = &c.w;
    w.s("<tr><td valign=\"top\">Фото</td><td><input type=\"file\" name=\"photo\" accept=\"image/*\"><br><span class=\"muted\">PNG, JPEG, GIF, WebP или SVG; уменьшается само.</span>");
    if (pr.hash != 0) w.s("<br><label><input type=\"checkbox\" name=\"nophoto\" value=\"1\"> убрать фото</label>");
    w.s("</td></tr>\n");
}

pub fn editPerson(c: *Ctx, pid: i32, msg: []const u8) void {
    const w = &c.w;
    if (pid <= 0) return c.notFound();
    const p = c.db.person(pid) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin?back=/c/{d}/edit", .{pid});
    if (!canEditPerson(c, pid)) return c.denied(T("Профиль автора правят сотрудники, /u/0 и привязанные к нему участники."));
    const pr = c.db.profile(pid);
    w.f("<h2>Профиль: {h}</h2>", .{p.name});
    c.msgBox(msg);
    w.f("<form action=\"/c/{d}/edit\" method=\"post\" enctype=\"multipart/form-data\" class=\"box\">", .{pid});
    c.post();
    w.f("\n<table><tr><td>Имя</td><td><input name=\"name\" size=\"40\" value=\"{h}\"></td></tr>\n<tr><td>Годы жизни</td><td><input name=\"years\" size=\"16\" value=\"{h}\"></td></tr>\n<tr><td valign=\"top\">О нём</td><td><textarea name=\"about\" rows=\"4\" cols=\"60\" style=\"width:100%\">{h}</textarea></td></tr>\n", .{ p.name, p.years, p.about });
    photoForm(c, pr);
    pinsForm(c, pr.pins);
    w.s("<tr><td></td><td><input type=\"submit\" value=\"Сохранить\"></td></tr></table></form>");
    c.page(.{ .title = T("Профиль"), .sec = "/c", .crumbs = &.{ .{ .text = T("Цитаты"), .href = "/c" }, .{ .text = p.name, .href = std.fmt.allocPrint(c.a, "/c/{d}", .{pid}) catch "/c" }, .{ .text = T("Профиль") } } });
}

pub fn editUser(c: *Ctx, uid: i32, msg: []const u8) void {
    const w = &c.w;
    const u = c.db.user(uid) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin?back=/u/{d}/edit", .{uid});
    if (!canEditUser(c, uid)) return c.denied(T("Профиль участника правят он сам, сотрудники и /u/0."));
    const pr = c.db.profile(uid);
    w.f("<h2>Профиль: {h}</h2>", .{u.nick});
    c.msgBox(msg);
    w.f("<form action=\"/u/{d}/edit\" method=\"post\" enctype=\"multipart/form-data\" class=\"box\">", .{uid});
    c.post();
    w.f("\n<table><tr><td valign=\"top\">О себе</td><td><textarea name=\"about\" rows=\"4\" cols=\"60\" style=\"width:100%\">{h}</textarea></td></tr>\n", .{u.about});
    photoForm(c, pr);
    pinsForm(c, pr.pins);
    w.s("<tr><td></td><td><input type=\"submit\" value=\"Сохранить\"></td></tr></table></form>");
    c.page(.{ .title = T("Профиль"), .sec = "/u", .crumbs = &.{ .{ .text = T("Авторы"), .href = "/u" }, .{ .text = u.nick, .href = std.fmt.allocPrint(c.a, "/u/{d}", .{uid}) catch "/u" }, .{ .text = T("Профиль") } } });
}

/// Фото и закреплённые из формы; null — фото не разобралось (сообщение — в why).
fn applyForm(c: *Ctx, id: i32, why: *[]const u8) ?dbm.Profile {
    var pr = c.db.profile(id);
    if (c.form.on("nophoto")) {
        pr.hash = 0;
        pr.kind = 0;
        pr.w = 0;
        pr.h = 0;
    }
    if (c.form.file("photo")) |f| if (f.value.len > 0) {
        var dir = c.app.img.makeOpenPath(imgstore.dir_name, .{}) catch {
            why.* = T("Папка картинок недоступна.");
            return null;
        };
        defer dir.close();
        var st = imgstore.Stats{};
        const im = imgstore.put(c.app.gpa, dir, .{ .bytes = f.value }, &st) orelse {
            why.* = T("Фото не разобралось: нужен PNG, JPEG, GIF, WebP или SVG.");
            return null;
        };
        pr.hash = im.hash;
        pr.kind = im.kind;
        pr.w = im.w;
        pr.h = im.h;
    };
    var pins = std.ArrayList(u8).init(c.a);
    for (c.form.fields) |f| {
        if (!std.mem.eql(u8, f.name, "pin")) continue;
        const v = std.mem.trim(u8, f.value, " ");
        const ok = v.len > 1 and v.len <= 12 and (v[0] == 'f' or v[0] == 'b') and std.mem.indexOfAny(u8, v, ",|\n") == null;
        if (!ok) continue;
        if (pins.items.len > 0) pins.append(',') catch break;
        pins.appendSlice(v) catch break;
    }
    pr.pins = pins.items;
    return pr;
}

pub fn editPersonPost(c: *Ctx, pid: i32) void {
    const p = c.db.person(pid) orelse return c.notFound();
    if (pid <= 0) return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEditPerson(c, pid)) return c.denied(T("Профиль автора правят сотрудники, /u/0 и привязанные к нему участники."));
    var why: []const u8 = "";
    const pr = applyForm(c, pid, &why) orelse {
        c.status = 400;
        return editPerson(c, pid, why);
    };
    const name = std.mem.trim(u8, c.form.get("name"), " \r\n\t");
    const years = std.mem.trim(u8, c.form.get("years"), " ");
    const about = std.mem.trim(u8, c.form.get("about"), " \r\n\t");
    c.db.l.put(L.key(c.a, "H", .{pid}), L.rec(c.a, .{ if (name.len > 0) name[0..@min(name.len, 120)] else p.name, years[0..@min(years.len, 30)], about[0..@min(about.len, 2000)] }));
    c.db.putProfile(pid, pr);
    c.app.rebuild_wanted = true;
    c.redirect("/c/{d}", .{pid});
}

pub fn editUserPost(c: *Ctx, uid: i32) void {
    var u = c.db.user(uid) orelse return c.notFound();
    if (c.me == null) return c.redirect("/signin", .{});
    if (!canEditUser(c, uid)) return c.denied(T("Профиль участника правят он сам, сотрудники и /u/0."));
    var why: []const u8 = "";
    const pr = applyForm(c, uid, &why) orelse {
        c.status = 400;
        return editUser(c, uid, why);
    };
    const about = std.mem.trim(u8, c.form.get("about"), " \r\n\t");
    u.about = about[0..@min(about.len, 1000)];
    c.db.putUser(u);
    c.db.putProfile(uid, pr);
    c.redirect("/u/{d}", .{uid});
}
