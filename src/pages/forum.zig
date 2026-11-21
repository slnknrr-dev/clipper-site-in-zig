//! Форумы (/f/N, для участников) и анонимные доски (/f/имя) с картинками
//! и автоудалением тредов по сроку жизни.

const std = @import("std");
const cp = @import("../cp1251.zig");
const http = @import("../http.zig");
const L = @import("../ledger.zig");
const dbm = @import("../db.zig");
const sys = @import("../sys.zig");
const auth = @import("../auth.zig");
const W = @import("../out.zig").W;
const Ctx = @import("../app.zig").Ctx;
const h = @import("h.zig");
const route = @import("../route.zig");

const T = cp.text;

fn ttl(c: *Ctx, m: i64) void {
    if (m >= 60) {
        c.w.int(@divTrunc(m, 60));
        if (@rem(m, 60) != 0) c.w.f(".{d}", .{@divTrunc(@rem(m, 60) * 10, 60)});
        c.w.s(" ч");
    } else c.w.f("{d} мин", .{m});
}

/// Удаляет треды, чей срок вышел (вместе с картинками).
pub fn purge(c: *Ctx) void {
    const now = sys.nowMs();
    for (c.db.boards()) |b| {
        const posts = c.db.ibPosts(b.id);
        var dead = std.ArrayList(dbm.IbPost).init(c.a);
        for (posts) |op| {
            if (op.no != op.thread or now - op.date < b.ttl_min * 60_000) continue;
            for (posts) |p| if (p.thread == op.thread) dead.append(p) catch {};
        }
        const bid = c.a.dupe(u8, b.id) catch continue;
        for (dead.items) |p| {
            if (p.img.len == 12) {
                c.app.img.deleteFile(p.img) catch {};
            }
            c.db.delIbPost(bid, p.thread, p.no);
        }
    }
}

fn threadCount(posts: []const dbm.IbPost) usize {
    var n: usize = 0;
    for (posts) |p| n += @intFromBool(p.no == p.thread);
    return n;
}

pub fn index(c: *Ctx) void {
    const w = &c.w;
    purge(c);
    c.no_cache = true;
    w.s("<h2>Форумы</h2>");
    var t = h.Table.begin(c, &.{ "№", "Форум", "Тем", "Описание" });
    for (c.db.forums()) |f| {
        t.row();
        w.f("<td>{d}</td><td><a href=\"{U}/f/{d}{E}\">{h}</a></td><td>{d}</td><td>{h}</td></tr>", .{ f.id, f.id, f.title, c.db.topics(f.id).len, f.about });
    }
    t.end();
    w.s("\n<h2>Анонимные доски</h2><p class=\"muted\">Без регистрации. Треды удаляются автоматически по истечении срока жизни.</p>");
    t = h.Table.begin(c, &.{ "Доска", "Название", "Тредов", "Срок жизни" });
    for (c.db.boards()) |b| {
        t.row();
        w.f("<td><a href=\"{U}/f/{s}{E}\">/{s}/</a></td><td>{h}</td><td>{d}</td><td>", .{ b.id, b.id, b.title, threadCount(c.db.ibPosts(b.id)) });
        ttl(c, b.ttl_min);
        w.raw("</td></tr>");
    }
    t.end();
    c.page(.{ .title = T("Форумы"), .sec = "/f", .crumbs = &.{.{ .text = T("Форумы") }} });
}

pub fn forum(c: *Ctx, id: i32) void {
    const w = &c.w;
    const f = c.db.forum(id) orelse return c.notFound();
    const tid = std.math.cast(i32, c.qInt("topic")) orelse 0;
    const f_href = std.fmt.allocPrint(c.a, "/f/{d}", .{id}) catch "/f";
    if (tid != 0) {
        const t = c.db.topic(id, tid) orelse return c.notFound();
        w.f("<h2>{h}</h2><table class=\"list\">", .{t.title});
        for (c.db.posts(tid)) |p| {
            w.f("<tr><td width=\"120\"><a name=\"p{d}\"></a>", .{p.id});
            c.aLink(p.author);
            w.f("<br><span class=\"muted\">{h}</span></td><td>{b}</td></tr>", .{ p.date, p.text });
        }
        w.s("</table>\n<h3>Ответить</h3>");
        if (h.gate(c, dbm.rights.forum, .forum)) {
            w.f("<form action=\"/f/{d}/reply\" method=\"post\" class=\"box\">", .{id});
            c.post();
            w.f("<input type=\"hidden\" name=\"topic\" value=\"{d}\">От имени: <b>{h}</b><br><textarea name=\"text\" rows=\"4\" cols=\"60\" style=\"width:100%\"></textarea><br><input type=\"submit\" value=\"Отправить\"></form>", .{ tid, c.db.name(c.me.?.user) });
        }
        return c.page(.{ .title = t.title, .sec = "/f", .crumbs = &.{ .{ .text = T("Форумы"), .href = "/f" }, .{ .text = f.title, .href = f_href }, .{ .text = t.title } } });
    }
    w.f("<h2>Форум: {h}</h2><p class=\"muted\">{h}</p>", .{ f.title, f.about });
    var t = h.Table.begin(c, &.{ "Тема", "Ответов", "Последнее" });
    for (c.db.topics(id)) |tp| {
        const posts = c.db.posts(tp.id);
        t.row();
        w.f("<td><a href=\"{U}/f/{d}?topic={d}{E}\">{h}</a></td><td>{d}</td><td>", .{ id, tp.id, tp.title, @as(i64, @intCast(posts.len)) - 1 });
        if (posts.len > 0) {
            w.f("{h} ", .{posts[posts.len - 1].date});
            c.aLink(posts[posts.len - 1].author);
        }
        w.raw("</td></tr>");
    }
    t.end();
    w.s("\n<h3>Новая тема</h3>");
    if (h.gate(c, dbm.rights.forum, .forum)) {
        w.f("<form action=\"/f/{d}/topic\" method=\"post\" class=\"box\">", .{id});
        c.post();
        w.s("Тема: <input name=\"title\" size=\"30\"><br><textarea name=\"text\" rows=\"4\" cols=\"60\" style=\"width:100%\"></textarea><br><input type=\"submit\" value=\"Создать\"></form>");
    }
    c.page(.{ .title = f.title, .sec = "/f", .crumbs = &.{ .{ .text = T("Форумы"), .href = "/f" }, .{ .text = f.title } } });
}

pub fn forumPost(c: *Ctx, a: []const u8, b: []const u8) void {
    if (!c.can(dbm.rights.forum, .forum)) return c.denied(T("Нет права участвовать на форуме или форум отключён."));
    const id = route.intId(a, true) orelse return c.notFound();
    _ = c.db.forum(id) orelse return c.notFound();
    const author = c.me.?.user;
    const text_raw = c.form.get("text");
    const text = if (text_raw.len > 0) text_raw else T("…");
    if (std.mem.eql(u8, b, "topic")) {
        const tid = c.db.nextId("topic", 1, 1);
        const title = c.form.get("title");
        c.db.l.put(L.key(c.a, "T", .{ id, tid }), L.rec(c.a, .{if (title.len > 0) title[0..@min(title.len, 200)] else T("Без темы")}));
        c.db.putPost(.{ .id = c.db.nextId("post", 1, 1), .topic = tid, .forum = id, .author = author, .date = c.today(), .text = text });
        return c.redirect("/f/{d}?topic={d}", .{ id, tid });
    }
    if (std.mem.eql(u8, b, "reply")) {
        const tid = std.math.cast(i32, c.form.int("topic") orelse 0) orelse 0;
        _ = c.db.topic(id, tid) orelse return c.notFound();
        c.db.putPost(.{ .id = c.db.nextId("post", 1, 1), .topic = tid, .forum = id, .author = author, .date = c.today(), .text = text });
        return c.redirect("/f/{d}?topic={d}", .{ id, tid });
    }
    c.notFound();
}

// ───────────── доски ─────────────

/// Текст поста: «>цитата» зелёным, «>>N» — ссылка на пост.
fn ibText(w: *W, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) w.raw("<br>");
        first = false;
        if (line.len > 0 and line[0] == '>' and !(line.len > 1 and line[1] == '>')) {
            w.raw("<span class=\"gt\">");
            w.esc(line);
            w.raw("</span>");
            continue;
        }
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '>' and i + 2 < line.len and line[i + 1] == '>' and std.ascii.isDigit(line[i + 2])) {
                var e = i + 2;
                while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
                w.f("<a href=\"#{s}\">&gt;&gt;{s}</a>", .{ line[i + 2 .. e], line[i + 2 .. e] });
                i = e;
            } else {
                w.esc(line[i .. i + 1]);
                i += 1;
            }
        }
    }
}

/// «02.04.2003, 12:34:56» (UTC).
pub fn ruTime(w: *W, ms: i64) void {
    const t = http.civil(@divFloor(ms, 1000));
    var b: [24]u8 = undefined;
    w.raw(std.fmt.bufPrint(&b, "{d:0>2}.{d:0>2}.{d}, {d:0>2}:{d:0>2}:{d:0>2}", .{ t.day, t.month, t.year, t.hour, t.min, t.sec }) catch "");
}

fn ibPost(c: *Ctx, p: dbm.IbPost, b: dbm.Board, op: bool) void {
    const w = &c.w;
    w.raw("<div class=\"ibpost\"");
    if (op) w.raw(" style=\"display:block;border:0;background:none\"");
    w.f("><a name=\"{d}\"></a>", .{p.no});
    if (p.img.len > 0) w.f("<a href=\"/img/{h}\"><img src=\"/img/{h}\" alt=\"\"></a>", .{ p.img, p.img });
    if (p.subj.len > 0) w.f("<b>{h}</b> ", .{p.subj});
    w.f("<b>{h}</b> <span class=\"muted\">", .{p.name});
    ruTime(w, p.date);
    const left_ms = b.ttl_min * 60_000 - (sys.nowMs() - p.date);
    w.f(" · №{d} · умрёт через {d} мин</span><br>", .{ p.no, @max(0, @divFloor(left_ms + 59_999, 60_000)) });
    ibText(w, p.text);
    w.raw("</div>");
}

fn postForm(c: *Ctx, b: dbm.Board, thread: i32) void {
    const w = &c.w;
    w.f("<form action=\"/f/{s}/post\" method=\"post\" enctype=\"multipart/form-data\" class=\"box\">", .{b.id});
    c.post();
    if (thread != 0) w.f("<input type=\"hidden\" name=\"th\" value=\"{d}\">", .{thread});
    w.s("\n<table><tr><td>Имя</td><td><input name=\"name\" value=\"Аноним\" size=\"20\"></td></tr>");
    if (thread == 0) w.s("<tr><td>Тема</td><td><input name=\"subj\" size=\"30\"></td></tr>");
    w.s("\n<tr><td>Текст</td><td><textarea name=\"text\" rows=\"4\" cols=\"50\"></textarea></td></tr><tr><td>Картинка</td><td><input type=\"file\" name=\"img\" accept=\"image/*\"></td></tr>\n<tr><td></td><td><input type=\"submit\" value=\"");
    if (thread != 0) w.s("Ответить") else w.s("Создать тред");
    w.s("\"> <span class=\"muted\">тред живёт ");
    ttl(c, b.ttl_min);
    w.raw("</span></td></tr></table></form>");
}

pub fn board(c: *Ctx, bid: []const u8) void {
    const w = &c.w;
    purge(c);
    c.no_cache = true;
    const b = c.db.board(bid) orelse return c.notFound();
    const posts = c.db.ibPosts(bid);
    const th = std.math.cast(i32, c.qInt("th")) orelse 0;
    const b_href = std.fmt.allocPrint(c.a, "/f/{s}", .{bid}) catch "/f";
    const slashed = std.fmt.allocPrint(c.a, "/{s}/", .{bid}) catch bid;
    if (th != 0) {
        var op: ?dbm.IbPost = null;
        for (posts) |p| if (p.thread == th and p.no == th) {
            op = p;
        };
        const o = op orelse {
            w.f("<h2>Тред №{d} не найден</h2><p>Скорее всего, он истёк и был автоматически удалён.</p><p><a href=\"{U}/f/{s}{E}\">Вернуться на /{s}/</a></p>", .{ th, bid, bid });
            return c.page(.{ .title = T("Тред удалён"), .sec = "/f", .crumbs = &.{ .{ .text = T("Форумы"), .href = "/f" }, .{ .text = slashed, .href = b_href }, .{ .text = T("тред умер") } } });
        };
        w.f("<h2>/{s}/ — {h}</h2>", .{ bid, b.title });
        postForm(c, b, th);
        w.raw("<hr>");
        ibPost(c, o, b, true);
        var first = true;
        for (posts) |p| {
            if (p.thread != th or p.no == th) continue;
            if (!first) w.raw("<br>");
            first = false;
            ibPost(c, p, b, false);
        }
        w.f("<hr><a href=\"{U}/f/{s}{E}\">[назад]</a>", .{bid});
        return c.page(.{
            .title = std.fmt.allocPrint(c.a, "/{s}/ \x97 \xB9{d}", .{ bid, th }) catch slashed,
            .sec = "/f",
            .crumbs = &.{ .{ .text = T("Форумы"), .href = "/f" }, .{ .text = std.fmt.allocPrint(c.a, "/{s}/ {s}", .{ bid, b.title }) catch slashed, .href = b_href }, .{ .text = std.fmt.allocPrint(c.a, "\xB9{d}", .{th}) catch "" } },
        });
    }
    w.f("<h2 align=\"center\">/{s}/ — {h}</h2>", .{ bid, b.title });
    postForm(c, b, 0);
    w.raw("<hr>");
    // треды по времени последнего поста, свежие сверху
    const Thread = struct { op: dbm.IbPost, bumped: i64, replies: usize };
    var threads = std.ArrayList(Thread).init(c.a);
    for (posts) |p| {
        if (p.no != p.thread) continue;
        var t = Thread{ .op = p, .bumped = p.date, .replies = 0 };
        for (posts) |r| if (r.thread == p.thread and r.no != p.no) {
            t.replies += 1;
            t.bumped = @max(t.bumped, r.date);
        };
        threads.append(t) catch break;
    }
    std.mem.sort(Thread, threads.items, {}, struct {
        fn lt(_: void, x: Thread, y: Thread) bool {
            return x.bumped > y.bumped;
        }
    }.lt);
    if (threads.items.len == 0) w.s("<p class=\"muted\">Тредов нет — все истекли. Создайте новый.</p>");
    for (threads.items) |t| {
        ibPost(c, t.op, b, true);
        w.f(" <a href=\"{U}/f/{s}?th={d}{E}\">[ответить]</a>", .{ bid, t.op.no });
        if (t.replies > 3) w.f("<div class=\"muted\">пропущено ответов: {d}</div>", .{t.replies - 3});
        var seen: usize = 0;
        for (posts) |r| {
            if (r.thread != t.op.no or r.no == t.op.no) continue;
            seen += 1;
            if (seen + 3 <= t.replies) continue;
            w.raw("<br>");
            ibPost(c, r, b, false);
        }
        w.raw("<hr style=\"clear:both\">");
    }
    // список досок в боковую колонку
    const side_buf = c.a.alloc(u8, 8192) catch "";
    var sw = W.init(@constCast(side_buf));
    sw.tm = w.tm;
    for (c.db.boards(), 0..) |x, i| {
        if (i > 0) sw.raw("<br>\n");
        sw.f("<a href=\"{U}/f/{s}{E}\">/{s}/ {h}</a>", .{ x.id, x.id, x.title });
    }
    c.page(.{
        .title = std.fmt.allocPrint(c.a, "/{s}/ \x97 {s}", .{ bid, b.title }) catch slashed,
        .sec = "/f",
        .crumbs = &.{ .{ .text = T("Форумы"), .href = "/f" }, .{ .text = std.fmt.allocPrint(c.a, "/{s}/ {s}", .{ bid, b.title }) catch slashed } },
        .side_head = T("Доски"),
        .side = sw.out(),
    });
}

/// Тип картинки по её первым байтам; null — не картинка.
pub fn imageType(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (std.mem.startsWith(u8, bytes, "BM") and bytes.len > 26) return "image/bmp";
    if (bytes.len > 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

pub fn boardPost(c: *Ctx, bid_raw: []const u8) void {
    if (!c.featureOpen(.boards)) return c.denied(T("Доски отключены."));
    if (!c.secWritable(.f)) return c.denied(T("Форумы и доски сейчас только для чтения."));
    purge(c);
    if (bid_raw.len > 8) return c.notFound();
    const bid = std.ascii.allocLowerString(c.a, bid_raw) catch return c.notFound();
    _ = c.db.board(bid) orelse return c.notFound();
    var img: []const u8 = "";
    var img_type: []const u8 = "";
    if (c.form.file("img")) |f| {
        if (f.value.len > 0 and f.value.len < 2_000_000) {
            if (imageType(f.value)) |ty| {
                var tok: [32]u8 = undefined;
                auth.randomToken(&tok);
                const name = c.a.dupe(u8, tok[0..12]) catch "";
                c.app.img.writeFile(.{ .sub_path = name, .data = f.value }) catch return c.fail(500, T("Картинка не сохранена."));
                img = name;
                img_type = ty;
            }
        }
    }
    const text = c.form.get("text");
    if (text.len == 0 and img.len == 0) return c.redirect("/f/{s}", .{bid});
    const name = c.form.get("name");
    const subj = c.form.get("subj");
    const th = std.math.cast(i32, c.form.int("th") orelse 0) orelse 0;
    if (th != 0) {
        var alive = false;
        for (c.db.ibPosts(bid)) |p| alive = alive or (p.thread == th and p.no == th);
        if (!alive) return c.redirect("/f/{s}?th={d}", .{ bid, th });
    }
    const no = c.db.nextId("ib", 1, 1);
    c.db.putIbPost(bid, .{
        .no = no,
        .thread = if (th != 0) th else no,
        .date = sys.nowMs(),
        .name = if (name.len > 0) name[0..@min(name.len, 40)] else T("Аноним"),
        .subj = subj[0..@min(subj.len, 80)],
        .img = img,
        .img_type = img_type,
        .text = text[0..@min(text.len, 8000)],
    });
    c.redirect("/f/{s}?th={d}", .{ bid, if (th != 0) th else no });
}

/// /img/{имя} — картинка поста доски.
pub fn image(c: *Ctx, name: []const u8) void {
    if (name.len != 12) return c.notFound();
    for (name) |ch| if (!std.ascii.isHex(ch)) return c.notFound();
    const bytes = c.app.img.readFileAlloc(c.app.gpa, name, 2_100_000) catch return c.notFound();
    c.reply.owned = bytes;
    c.reply.header("Cache-Control: max-age=86400", .{});
    c.reply.header("X-Content-Type-Options: nosniff", .{});
    c.send(imageType(bytes) orelse "application/octet-stream", bytes);
}
