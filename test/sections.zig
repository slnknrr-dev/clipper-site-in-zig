//! Архетипы сайта (DIGITALLIBRARY_RU_RND.md): для каждого сочетания флагов -M, -R, -G, -N,
//! каждой темы и обеих версий (полной и мобильной) проверяется:
//!   — выключенные разделы отвечают 404, закрытые для гостя ведут на вход;
//!   — в меню и на главной нет ссылок на выключенное и закрытое;
//!   — форм записи нет там, где действует -R или -M (для не модератора).

const std = @import("std");
const testing = std.testing;
const clipper = @import("clipper");
const fixture = @import("fixture.zig");
const http = clipper.http;
const App = clipper.app.App;
const Reply = clipper.server.Reply;
const S = clipper.sections;

const Got = struct { status: u16, body: []u8 };

const Client = struct {
    app: *App,
    cookie_buf: [160]u8 = undefined,
    cookie: []const u8 = "",
    req_buf: [4096]u8 = undefined,
    /// дополнительные строки заголовка, каждая с CRLF на конце
    extra: []const u8 = "",

    const csrf = "0123456789abcdef0123456789abcdef";

    fn send(v: *Client, a: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) !Got {
        var w = std.io.fixedBufferStream(&v.req_buf);
        try w.writer().print("{s} {s} HTTP/1.1\r\nHost: test\r\nCookie: csrf={s}{s}{s}\r\n", .{ method, target, csrf, if (v.cookie.len > 0) "; sid=" else "", v.cookie });
        try w.writer().writeAll(v.extra);
        if (body.len > 0) try w.writer().print("Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n", .{body.len});
        try w.writer().writeAll("\r\n");
        const req = switch (http.parse(w.getWritten())) {
            .ok => |r| r,
            else => return error.BadRequest,
        };
        var reply = Reply{};
        v.app.handle(&req, body, clipper.net.loopback, false, &reply);
        defer if (reply.owned) |o| v.app.gpa.free(o);
        if (std.mem.indexOf(u8, reply.extra[0..reply.extra_len], "Set-Cookie: sid=")) |i| {
            const rest = reply.extra[i + 16 .. reply.extra_len];
            const end = std.mem.indexOfAny(u8, rest, ";\r") orelse rest.len;
            @memcpy(v.cookie_buf[0..end], rest[0..end]);
            v.cookie = v.cookie_buf[0..end];
        }
        return .{ .status = reply.status, .body = try a.dupe(u8, reply.body) };
    }

    /// multipart/form-data: поля и один файл (имя поля file_field).
    fn sendMultipart(v: *Client, a: std.mem.Allocator, target: []const u8, fields: []const [2][]const u8, file_field: []const u8, file_name: []const u8, file: []const u8) !Got {
        const boundary = "----clipperTestBoundary7";
        var body = std.ArrayList(u8).init(a);
        for (fields) |f| try body.writer().print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, f[0], f[1] });
        try body.writer().print("--{s}\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n", .{ boundary, csrf });
        try body.writer().print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, file_field, file_name });
        try body.appendSlice(file);
        try body.writer().print("\r\n--{s}--\r\n", .{boundary});
        var w = std.io.fixedBufferStream(&v.req_buf);
        try w.writer().print("POST {s} HTTP/1.1\r\nHost: test\r\nCookie: csrf={s}{s}{s}\r\nContent-Type: multipart/form-data; boundary={s}\r\nContent-Length: {d}\r\n\r\n", .{ target, csrf, if (v.cookie.len > 0) "; sid=" else "", v.cookie, boundary, body.items.len });
        const req = switch (http.parse(w.getWritten())) {
            .ok => |r| r,
            else => return error.BadRequest,
        };
        var reply = Reply{};
        v.app.handle(&req, body.items, clipper.net.loopback, false, &reply);
        defer if (reply.owned) |o| v.app.gpa.free(o);
        return .{ .status = reply.status, .body = try a.dupe(u8, reply.body) };
    }

    fn get(v: *Client, a: std.mem.Allocator, target: []const u8) !Got {
        return v.send(a, "GET", target, "");
    }

    fn signin(v: *Client, a: std.mem.Allocator, login: []const u8) !void {
        var b: [96]u8 = undefined;
        const body = try std.fmt.bufPrint(&b, "login={s}&pass={s}&_csrf={s}", .{ login, login, csrf });
        try testing.expectEqual(@as(u16, 303), (try v.send(a, "POST", "/signin", body)).status);
    }
};

/// Есть ли на странице ссылка на раздел: href="/x" или href="/x?..." или "/x/...".
fn linksTo(body: []const u8, sec: u8) bool {
    var pat = [_]u8{ 'h', 'r', 'e', 'f', '=', '"', '/', sec, 0 };
    for ("\"?/") |end| {
        pat[8] = end;
        if (std.mem.indexOf(u8, body, &pat) != null) return true;
    }
    return false;
}

const Case = struct { name: []const u8, rules: S.Rules };

fn bits(comptime s: []const u8) S.Set {
    var msg: []const u8 = "";
    return S.parseSet(s, &msg).?;
}

const cases = [_]Case{
    .{ .name = "A полный", .rules = .{} },
    .{ .name = "B песенник", .rules = .{ .off = bits("bdfq") } },
    .{ .name = "C читальня", .rules = .{ .off = bits("dfpq"), .mod = bits("b") } },
    .{ .name = "C' читальня с цитатами", .rules = .{ .off = bits("dfp") } },
    .{ .name = "D форум", .rules = .{ .off = bits("bdpq"), .ro = bits("f") } },
    .{ .name = "E цитатник", .rules = .{ .off = bits("bdfp") } },
    .{ .name = "F мастерская", .rules = .{ .off = bits("bq") } },
    .{ .name = "гостям только стихи", .rules = .{ .guest = bits("p"), .guest_set = true } },
};

const section_paths = [_]struct { u8, S.Sec, []const u8 }{
    .{ 'p', .p, "/p" }, .{ 'b', .b, "/b" }, .{ 'd', .d, "/d" }, .{ 'f', .f, "/f" }, .{ 'c', .q, "/c" },
};

test "архетипы: доступ, меню и главная во всех темах и версиях" {
    for (cases) |cs| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [128]u8 = undefined;
        const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try fixture.prepare(testing.allocator, root, false);
        const app = try App.init(testing.allocator, .{ .root = root, .sec = cs.rules }, true);
        defer app.deinit();
        var guest = Client{ .app = app };
        var reader = Client{ .app = app };
        try reader.signin(a, "reader");
        errdefer std.debug.print("\nархетип: {s}\n", .{cs.name});

        for (section_paths) |sp| {
            const off = S.Rules.has(cs.rules.off, sp[1]);
            const g = try guest.get(a, sp[2]);
            const r = try reader.get(a, sp[2]);
            if (off) {
                try testing.expectEqual(@as(u16, 404), g.status);
                try testing.expectEqual(@as(u16, 404), r.status);
            } else {
                try testing.expectEqual(@as(u16, 200), r.status);
                try testing.expectEqual(@as(u16, if (cs.rules.guestOk(sp[1])) 200 else 303), g.status);
            }
            // меню и главная: нет ссылок на выключенное; у гостя — и на закрытое
            for ([_][]const u8{ "flibusta", "samlib", "proza", "nepomn" }) |th| {
                for ([_][]const u8{ "false", "true" }) |m| {
                    const url = try std.fmt.allocPrint(a, "/?t={s}&m={s}", .{ th, m });
                    const gh = try guest.get(a, url);
                    const rh = try reader.get(a, url);
                    try testing.expectEqual(@as(u16, 200), gh.status);
                    try testing.expectEqual(@as(u16, 200), rh.status);
                    if (off) {
                        try testing.expect(!linksTo(rh.body, sp[0]));
                        try testing.expect(!linksTo(gh.body, sp[0]));
                    }
                    if (!cs.rules.guestOk(sp[1])) try testing.expect(!linksTo(gh.body, sp[0]));
                }
            }
        }
        // запись: -R и -M закрывают формы для обычного участника
        if (S.Rules.has(cs.rules.ro, .f)) {
            const f = try reader.get(a, "/f/1?topic=1");
            try testing.expect(std.mem.indexOf(u8, f.body, "action=\"/f/1/") == null);
        }
        if (S.Rules.has(cs.rules.mod, .b)) {
            const b = try reader.get(a, "/b");
            try testing.expect(std.mem.indexOf(u8, b.body, "/b/upload") == null);
            const up = try reader.get(a, "/b/upload");
            try testing.expect(std.mem.indexOf(u8, up.body, "action=\"/b/upload") == null);
        }
        // цитатник: книга 0 открывается на чтение, но списка книг нет
        if (cs.rules.booksHidden()) {
            try testing.expectEqual(@as(u16, 200), (try reader.get(a, "/b/0/1")).status);
            try testing.expectEqual(@as(u16, 404), (try reader.get(a, "/b")).status);
            try testing.expectEqual(@as(u16, 404), (try reader.get(a, "/b/upload")).status);
            try testing.expectEqual(@as(u16, 404), (try reader.get(a, "/b/0/txt")).status);
        }
    }
}

// ───────────── обход сайта ─────────────

/// Названия разделов в тексте страниц (windows-1251). С заглавной — так их пишут меню и заголовки.
const words = [_]struct { S.Sec, []const []const u8 }{
    .{ .p, &.{ clipper.cp1251.text("Стихи"), clipper.cp1251.text("Песни") } },
    .{ .b, &.{ clipper.cp1251.text("Книги"), clipper.cp1251.text("Серии") } },
    .{ .d, &.{ clipper.cp1251.text("Черновик"), clipper.cp1251.text("Статьи") } },
    .{ .f, &.{ clipper.cp1251.text("Форум"), clipper.cp1251.text("Анонимные доски") } },
    .{ .q, &.{ clipper.cp1251.text("Цитат"), clipper.cp1251.text("Персонаж") } },
};

/// Раздел адреса, как его видит сервер (null — адрес не раздела).
fn secOf(path: []const u8) ?S.Sec {
    var p = path;
    if (std.mem.startsWith(u8, p, "/e/") or std.mem.startsWith(u8, p, "/x/")) p = p[2..];
    if (std.mem.startsWith(u8, p, "/bookmarks")) return .b;
    if (p.len < 2 or p[0] != '/' or (p.len > 2 and std.mem.indexOfScalar(u8, "/?#.", p[2]) == null)) return null;
    return switch (p[1]) {
        'p' => .p,
        'b', 'q' => .b,
        'd' => .d,
        'f' => .f,
        'c' => .q,
        else => null,
    };
}

/// Текст интерфейса: заголовки, ссылки, шапки таблиц, заголовок окна. Так
/// разделы называет сам сайт; описания и тексты участников (они могут
/// упоминать что угодно) сюда не попадают.
fn textOf(a: std.mem.Allocator, html: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const tags = [_][]const u8{ "a", "h1", "h2", "h3", "h4", "h5", "th", "title" };
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt + 1;
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse break;
        const tag_raw = html[lt + 1 .. gt];
        const name_end = std.mem.indexOfAny(u8, tag_raw, " \t") orelse tag_raw.len;
        const name = tag_raw[0..name_end];
        for (tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) {
            var close_buf: [16]u8 = undefined;
            const close = try std.fmt.bufPrint(&close_buf, "</{s}>", .{t});
            const stop = std.ascii.indexOfIgnoreCasePos(html, gt, close) orelse html.len;
            // текст внутри без вложенных тегов
            var k = gt + 1;
            var in_tag = false;
            while (k < stop) : (k += 1) {
                if (html[k] == '<') in_tag = true else if (html[k] == '>') in_tag = false else if (!in_tag) try out.append(html[k]);
            }
            try out.append('|');
            break;
        };
    }
    return out.items;
}

/// Можно ли видеть раздел этому посетителю: включён и (вошёл или открыт гостям).
fn visible(r: S.Rules, s: S.Sec, signed: bool) bool {
    if (S.Rules.has(r.off, s)) return false;
    return signed or r.guestOk(s);
}

/// Страницы с текстом произведений: в них слова «Книги», «Форум» могут быть частью текста.
fn contentPage(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/b/") or std.mem.startsWith(u8, path, "/q/")) {
        var it = std.mem.splitScalar(u8, path[3..], '/');
        _ = it.next();
        return it.next() != null or std.mem.startsWith(u8, path, "/q/");
    }
    return std.mem.startsWith(u8, path, "/p/") or std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/f/");
}

fn crawl(a: std.mem.Allocator, v: *Client, r: S.Rules, signed: bool, th: []const u8, m: []const u8) !usize {
    var seen = std.StringHashMap(void).init(a);
    var queue = std.ArrayList([]const u8).init(a);
    for ([_][]const u8{ "/", "/help", "/u", "/u/-101", "/u/1001", "/e", "/s?q=%E0" }) |p| try queue.append(p);
    var done: usize = 0;
    while (queue.items.len > 0 and done < 160) {
        const path = queue.orderedRemove(0);
        if (seen.contains(path)) continue;
        try seen.put(path, {});
        const url = try std.fmt.allocPrint(a, "{s}{s}t={s}&m={s}", .{ path, if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?", th, m });
        const got = try v.get(a, url);
        done += 1;
        if (got.status != 200) continue;
        // страница в windows-1251 не должна содержать русского текста в UTF-8 (строка
        // ушла мимо перекодировки — w.raw вместо w.s): три кириллические пары подряд
        if (utf8Cyrillic(got.body)) |at| {
            std.debug.print("\nна {s} текст в UTF-8, а не в windows-1251: …{s}…\n", .{ path, got.body[at -| 40..@min(got.body.len, at + 40)] });
            return error.Utf8OnCp1251Page;
        }
        // ссылки: ни одной на невидимый раздел (скрытые книги цитатника открываются из цитат — это разрешено)
        var it = std.mem.splitSequence(u8, got.body, "href=\"");
        _ = it.next();
        while (it.next()) |rest| {
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const href = rest[0..end];
            if (href.len == 0 or href[0] != '/' or std.mem.startsWith(u8, href, "//")) continue;
            if (secOf(href)) |s| {
                const hidden_ok = s == .b and r.booksHidden() and !std.mem.eql(u8, href[0..@min(href.len, 2)], "/q") and secOfIsBook(href);
                if (!visible(r, s, signed) and !hidden_ok) {
                    std.debug.print("\nссылка на невидимый раздел: {s} → {s}\n", .{ path, href });
                    return error.LinkToHidden;
                }
            }
            const q = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
            const bare = href[0..q];
            if (std.mem.endsWith(u8, bare, "/txt") or std.mem.endsWith(u8, bare, "/fb2") or std.mem.endsWith(u8, bare, "/epub")) continue;
            if (std.mem.startsWith(u8, bare, "/logout") or std.mem.startsWith(u8, bare, "/files") or std.mem.startsWith(u8, bare, "/x/") or std.mem.startsWith(u8, bare, "/theme") or std.mem.startsWith(u8, bare, "/css") or std.mem.startsWith(u8, bare, "/g/")) continue;
            if (!seen.contains(bare)) try queue.append(try a.dupe(u8, bare));
        }
        // названия невидимых разделов в тексте служебных страниц
        if (!contentPage(path)) {
            const text = try textOf(a, got.body);
            for (words) |wd| {
                if (visible(r, wd[0], signed)) continue;
                if (wd[0] == .b and r.booksHidden()) continue;
                for (wd[1]) |word| if (std.mem.indexOf(u8, text, word)) |at| {
                    std.debug.print("\nна {s} названо невидимое: «{s}» …{s}…\n", .{ path, try clipper.cp1251.toUtf8Alloc(a, word), try clipper.cp1251.toUtf8Alloc(a, text[at -| 60..@min(text.len, at + 60)]) });
                    return error.HiddenSectionNamed;
                };
            }
        }
    }
    return done;
}

/// Начало трёх подряд кириллических букв в UTF-8 (D0/D1 и байт 80–BF). В русском
/// тексте windows-1251 такого сочетания не бывает: это «РђР±» вместо «Аб».
fn utf8Cyrillic(body: []const u8) ?usize {
    var i: usize = 0;
    while (i + 6 <= body.len) : (i += 1) {
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            const x = body[i + 2 * k];
            const y = body[i + 2 * k + 1];
            if (!((x == 0xD0 or x == 0xD1) and y >= 0x80 and y <= 0xBF)) break;
        }
        if (k == 3) return i;
    }
    return null;
}

/// Книга цитатника: /b/N и /b/N/K, но не список /b, не серии и не выкладывание.
fn secOfIsBook(href: []const u8) bool {
    if (!std.mem.startsWith(u8, href, "/b/")) return false;
    const rest = href[3..];
    return rest.len > 0 and std.ascii.isDigit(rest[0]);
}

test "обход: ни ссылок на невидимые разделы, ни их названий" {
    for (cases[1..]) |cs| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [128]u8 = undefined;
        const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        try fixture.prepare(testing.allocator, root, false);
        const app = try App.init(testing.allocator, .{ .root = root, .sec = cs.rules }, true);
        defer app.deinit();
        var guest = Client{ .app = app };
        var reader = Client{ .app = app };
        try reader.signin(a, "reader");
        errdefer std.debug.print("архетип: {s}\n", .{cs.name});
        for ([_][]const u8{ "flibusta", "samlib", "proza", "nepomn" }) |th| {
            for ([_][]const u8{ "false", "true" }) |m| {
                _ = try crawl(a, &guest, cs.rules, false, th, m);
                _ = try crawl(a, &reader, cs.rules, true, th, m);
            }
        }
    }
}

test "пустой сайт: без заготовки все разделы открываются и пусты, ошибок нет" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const app = try App.init(testing.allocator, .{ .root = root }, true);
    defer app.deinit();
    var guest = Client{ .app = app };
    for ([_][]const u8{ "/", "/p", "/b", "/c", "/d", "/f", "/u", "/s?q=a", "/help", "/e", "/e/stat", "/f/1", "/f/b", "/p/1", "/u/1001" }) |p| {
        const got = try guest.get(a, p);
        errdefer std.debug.print("\n{s}: {d}\n", .{ p, got.status });
        try testing.expect(got.status < 500);
    }
    // ни одного стиха, участника, форума или доски в программе нет
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/p/1")).status);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/u/1001")).status);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/f/1")).status);
    try testing.expectEqual(@as(usize, 0), app.snap.pieces.len);
    for ([_][]const u8{ "flibusta", "samlib", "proza", "nepomn" }) |th| {
        for ([_][]const u8{ "false", "true" }) |m| _ = try crawl(a, &guest, .{}, false, th, m);
    }
}

test "панель: /u/0 заводит форум и доску" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const app = try App.init(testing.allocator, .{ .root = root, .admin_pass = "rootpass" }, true);
    defer app.deinit();
    app.loadAdmin();
    var admin = Client{ .app = app };
    {
        const body = "login=admin&pass=rootpass&_csrf=" ++ Client.csrf;
        try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", "/signin", body)).status);
    }
    const panel = try admin.get(a, "/panel");
    try testing.expect(std.mem.indexOf(u8, panel.body, "action=\"/panel/forums\"") != null);
    _ = try admin.send(a, "POST", "/panel/forums", "kind=forum&title=Talk&about=All&_csrf=" ++ Client.csrf);
    _ = try admin.send(a, "POST", "/panel/forums", "kind=board&id=zz&title=Zz&ttl=60&_csrf=" ++ Client.csrf);
    // плохой адрес доски — не заводится
    _ = try admin.send(a, "POST", "/panel/forums", "kind=board&id=123&title=No&ttl=60&_csrf=" ++ Client.csrf);
    _ = try admin.send(a, "POST", "/panel/forums", "kind=board&id=zz&title=Again&ttl=60&_csrf=" ++ Client.csrf);
    var guest = Client{ .app = app };
    try testing.expectEqual(@as(u16, 200), (try guest.get(a, "/f/1")).status);
    const board = try guest.get(a, "/f/zz");
    try testing.expectEqual(@as(u16, 200), board.status);
    try testing.expect(std.mem.indexOf(u8, board.body, "Zz") != null);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/f/123")).status);
    const list = try guest.get(a, "/f");
    try testing.expect(std.mem.indexOf(u8, list.body, "Talk") != null);
    try testing.expect(std.mem.indexOf(u8, list.body, "Again") == null);
}

test "снимок: -zstd — словарь из файла, кадр из словаря, смена словаря пересобирает снимок" {
    if (!@import("clipper").snapshot.has_zstd) {
        // сборка без zstd: нет ни флага -zstd, ни команды clipper zstd
        var msg: []const u8 = "";
        try testing.expectError(error.Usage, clipper.cli.parse(&.{ "clipper", "-p", "3000", "-zstd" }, &msg));
        try testing.expectError(error.Usage, clipper.cli.parse(&.{ "clipper", "zstd", "16" }, &msg));
        return;
    }
    const zfile = clipper.snapshot.zfile;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // словари: кусок текста книги 0 — для кадров 16 и 32 КБ
    const sample = "Клиппер — цифровая библиотека. Снимок каталога, кадры, словарь, страница чтения. " ** 40;
    for ([_]u32{ 16, 32 }) |kb| {
        var nb: [32]u8 = undefined;
        try tmp.dir.writeFile(.{ .sub_path = zfile.fileName(&nb, kb), .data = try zfile.encode(a, kb, sample) });
    }
    const ZCase = struct { spec: zfile.Spec, codec: u32, kb: u32 };
    const zcases = [_]ZCase{
        .{ .spec = .off, .codec = 0, .kb = 16 },
        .{ .spec = .{ .path = try std.fmt.allocPrint(a, "{s}/clipper16.zstd", .{root}) }, .codec = 1, .kb = 16 },
        .{ .spec = .{ .path = try std.fmt.allocPrint(a, "{s}/clipper32.zstd", .{root}) }, .codec = 1, .kb = 32 },
    };
    var pages: [zcases.len][]u8 = undefined;
    var gens: [zcases.len]u32 = undefined;
    for (zcases, 0..) |c, k| {
        const app = try App.init(testing.allocator, .{ .root = root, .zstd = c.spec }, true);
        defer app.deinit();
        try testing.expectEqual(c.codec, app.snap.h.codec);
        try testing.expectEqual(c.kb, app.snap.h.frame_kb);
        gens[k] = app.snap.h.gen;
        var guest = Client{ .app = app };
        const got = try guest.get(a, "/b/0/3");
        try testing.expectEqual(@as(u16, 200), got.status);
        pages[k] = got.body;
        // все кадры читаются и не больше кадра словаря
        var buf: [clipper.snapshot.frame_max]u8 = undefined;
        for (0..app.snap.frames.len) |i| try testing.expect((try app.snap.frame(@intCast(i), &buf)).len <= c.kb * 1024);
    }
    // одна и та же страница при любом способе и кадре; каждая смена — новый снимок
    for (pages[1..]) |p| try testing.expectEqualStrings(pages[0], p);
    try testing.expect(gens[0] < gens[1] and gens[1] < gens[2]);
    // тот же словарь — снимок не пересобирается
    {
        const app = try App.init(testing.allocator, .{ .root = root, .zstd = zcases[2].spec }, true);
        defer app.deinit();
        try testing.expectEqual(gens[2], app.snap.h.gen);
    }
    // испорченный и несуществующий словарь — понятные ошибки, снимок не трогается
    try tmp.dir.writeFile(.{ .sub_path = "bad.zstd", .data = "CLIPZDIC мусор" });
    const bad = try std.fmt.allocPrint(a, "{s}/bad.zstd", .{root});
    try testing.expectError(error.BadDict, App.init(testing.allocator, .{ .root = root, .zstd = .{ .path = bad } }, true));
    const none = try std.fmt.allocPrint(a, "{s}/none.zstd", .{root});
    try testing.expectError(error.NoDict, App.init(testing.allocator, .{ .root = root, .zstd = .{ .path = none } }, true));
    try testing.expectEqual(@as(u32, 0), clipper.snapshot.active.hash);
}

test "картинки книг: FB2 → хранилище img/b, рамка в тексте, обложка, уборка" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // широкая непрозрачная (станет JPEG 800×400) и маленькая прозрачная (останется PNG)
    const wide = try a.alloc(u8, 1600 * 800 * 4);
    for (0..800) |y| for (0..1600) |x| {
        wide[(y * 1600 + x) * 4 ..][0..4].* = .{ @intCast(x % 256), @intCast(y % 256), 90, 255 };
    };
    var clear: [40 * 20 * 4]u8 = undefined;
    for (0..800) |k| clear[k * 4 ..][0..4].* = .{ 200, 10, 10, if (k % 2 == 0) 0 else 255 };
    const wide_png = try clipper.png.encode(a, .{ .w = 1600, .h = 800, .px = wide });
    const clear_png = try clipper.png.encode(a, .{ .w = 40, .h = 20, .px = &clear });
    const E = std.base64.standard.Encoder;
    const b64 = struct {
        fn f(al: std.mem.Allocator, b: []const u8) ![]u8 {
            const out = try al.alloc(u8, E.calcSize(b.len));
            return @constCast(E.encode(out, b));
        }
    }.f;
    const fb2_text = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink">
        \\<description><title-info><book-title>С картинками</book-title><coverpage><image l:href="#w"/></coverpage></title-info></description>
        \\<body><section><title><p>Первая</p></title><p>До.</p><image l:href="#w" title="Широкая"/><p>Между.</p><image l:href="#c"/><image l:href="#нет"/><p>После.</p></section></body>
        \\<binary id="w">{s}</binary><binary id="c">{s}</binary></FictionBook>
    , .{ try b64(a, wide_png), try b64(a, clear_png) });
    try tmp.dir.makePath("books");
    try tmp.dir.writeFile(.{ .sub_path = "books/7.fb2", .data = fb2_text });

    var img_names: [2][]const u8 = undefined;
    {
        const app = try App.init(testing.allocator, .{ .root = root }, true);
        defer app.deinit();
        const s = &app.snap;
        try testing.expectEqual(@as(usize, 2), s.images.len); // две в тексте, обложка — та же, что первая
        var b: ?*const clipper.snapshot.Book = null;
        for (s.books) |*x| if (x.cover != 0) {
            b = x;
        };
        const bk = b.?;
        const cover = s.cover(bk).?;
        try testing.expectEqual(@as(u16, 800), cover.w);
        try testing.expectEqual(@as(u16, 400), cover.h);
        try testing.expectEqual(@intFromEnum(clipper.image.Kind.jpg), cover.kind);
        var guest = Client{ .app = app };
        // страница чтения: две рамки, метка несуществующей картинки ушла, абзацы на месте
        const page = try guest.get(a, try std.fmt.allocPrint(a, "/b/{d}/1", .{bk.id}));
        try testing.expectEqual(@as(u16, 200), page.status);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, page.body, "class=\"fig\""));
        try testing.expect(std.mem.indexOf(u8, page.body, "\x01") == null);
        try testing.expect(std.mem.indexOf(u8, page.body, "width=\"800\" height=\"400\"") != null);
        // вписана и по центру: по ширине целиком, сверху поле (600-400)/2/600
        try testing.expect(std.mem.indexOf(u8, page.body, "left:0.00%;top:16.67%;width:100.00%;height:66.67%") != null);
        // маленькая прозрачная не растягивается: 40×20 по центру места
        try testing.expect(std.mem.indexOf(u8, page.body, "width=\"40\" height=\"20\" alt=\"\" style=\"position:absolute;left:47.50%;top:48.33%") != null);
        // страница книги: обложка в месте 300×400
        const card = try guest.get(a, try std.fmt.allocPrint(a, "/b/{d}", .{bk.id}));
        try testing.expect(std.mem.indexOf(u8, card.body, "max-width:300px") != null);
        // файлы отдаются; чужие имена — нет
        for (s.images[0..2], 0..) |im, k| {
            var nb: [24]u8 = undefined;
            img_names[k] = try a.dupe(u8, clipper.imgstore.fileName(&nb, im.hash, @enumFromInt(im.kind)));
            const got = try guest.get(a, try std.fmt.allocPrint(a, "/img/b/{s}", .{img_names[k]}));
            try testing.expectEqual(@as(u16, 200), got.status);
            try testing.expect(clipper.image.info(got.body) != null);
        }
        try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/img/b/..%2F..%2Fx.jpg")).status);
        // текст для выгрузки — без меток картинок
        const txt = try guest.get(a, try std.fmt.allocPrint(a, "/b/{d}/txt", .{bk.id}));
        try testing.expectEqual(@as(u16, 200), txt.status);
        try testing.expect(std.mem.indexOf(u8, txt.body, "Между.") != null); // выгрузка txt — в UTF-8
        try testing.expect(std.mem.indexOf(u8, txt.body, "\x01") == null);
    }
    // книги больше нет: после двух пересборок её картинки убраны из хранилища
    try tmp.dir.deleteFile("books/7.fb2");
    for (0..2) |_| {
        const app = try App.init(testing.allocator, .{ .root = root }, true);
        defer app.deinit();
        _ = try clipper.library.build(testing.allocator, app.root, app.img, &app.ledger, .deflate, false);
    }
    for (img_names) |n| {
        const p = try std.fmt.allocPrint(a, "img/b/{s}", .{n});
        try testing.expectError(error.FileNotFound, tmp.dir.access(p, .{}));
    }
}

test "картинки книг: GIF, WebP и SVG; папка картинок из -img" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/lib", .{tmp.sub_path});
    const pics = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/картинки/книжные", .{tmp.sub_path});
    const files = [_]struct { id: []const u8, bytes: []const u8 }{
        .{ .id = "g", .bytes = @embedFile("img/drawing.gif") },
        .{ .id = "wl", .bytes = @embedFile("img/lossy.webp") },
        .{ .id = "wa", .bytes = @embedFile("img/alpha.webp") },
        .{ .id = "s", .bytes = @embedFile("img/shapes.svg") },
    };
    var body = std.ArrayList(u8).init(a);
    var bins = std.ArrayList(u8).init(a);
    for (files) |f| {
        try body.writer().print("<image l:href=\"#{s}\"/><p>Абзац.</p>", .{f.id});
        const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(f.bytes.len));
        try bins.writer().print("<binary id=\"{s}\">{s}</binary>", .{ f.id, std.base64.standard.Encoder.encode(enc, f.bytes) });
    }
    const book = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink">
        \\<description><title-info><book-title>Форматы</book-title></title-info></description>
        \\<body><section><title><p>Все</p></title>{s}</section></body>{s}</FictionBook>
    , .{ body.items, bins.items });
    try tmp.dir.makePath("lib/books");
    try tmp.dir.writeFile(.{ .sub_path = "lib/books/9.fb2", .data = book });

    const app = try App.init(testing.allocator, .{ .root = root, .img = pics }, true);
    defer app.deinit();
    const s = &app.snap;
    try testing.expectEqual(@as(usize, 4), s.images.len);
    const Kind = clipper.image.Kind;
    // GIF без прозрачности — JPEG; WebP с потерями без альфы — JPEG; с альфой — PNG; SVG — всегда PNG
    const want = [_]Kind{ .jpg, .jpg, .png, .png };
    for (s.images, want) |im, k| try testing.expectEqual(@intFromEnum(k), im.kind);
    // SVG — в своём размере (400×300), растровые — свои (333×217 и 200×120)
    try testing.expectEqual(@as(u16, 400), s.images[3].w);
    try testing.expectEqual(@as(u16, 300), s.images[3].h);
    try testing.expectEqual(@as(u16, 333), s.images[0].w);
    // файлы — в папке -img (создана сама), в ROOTDIR/img их нет
    var guest = Client{ .app = app };
    for (s.images) |im| {
        var nb: [24]u8 = undefined;
        const name = clipper.imgstore.fileName(&nb, im.hash, @enumFromInt(im.kind));
        const p = try std.fmt.allocPrint(a, "картинки/книжные/b/{s}", .{name});
        try tmp.dir.access(p, .{});
        try testing.expectError(error.FileNotFound, tmp.dir.access(try std.fmt.allocPrint(a, "lib/img/b/{s}", .{name}), .{}));
        const got = try guest.get(a, try std.fmt.allocPrint(a, "/img/b/{s}", .{name}));
        try testing.expectEqual(@as(u16, 200), got.status);
        // готовый файл разбирается своим же разбором и совпадает по размеру
        const img = try clipper.image.decodeAny(a, got.body);
        try testing.expectEqual(@as(u32, im.w), img.w);
        try testing.expectEqual(@as(u32, im.h), img.h);
    }
    const page = try guest.get(a, try std.fmt.allocPrint(a, "/b/{d}/1", .{s.books[s.books.len - 1].id}));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, page.body, "class=\"fig\""));
}

/// Поле формы: UTF-8 → windows-1251 → %XX (страницы и формы сайта — в windows-1251).
fn formField(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, utf8: []const u8) !void {
    if (out.items.len > 0) try out.append('&');
    try out.appendSlice(name);
    try out.append('=');
    for (try clipper.cp1251.encodeAlloc(a, utf8)) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(ch) else try out.writer().print("%{X:0>2}", .{ch});
    }
}

fn formOf(a: std.mem.Allocator, fields: []const [2][]const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (fields) |f| try formField(a, &out, f[0], f[1]);
    try out.writer().print("&_csrf={s}", .{Client.csrf});
    return out.items;
}

test "стихи от имени автора: выложить, ChordPro, права на правку, привязка к автору" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fixture.prepare(testing.allocator, root, false);
    const app = try App.init(testing.allocator, .{ .root = root, .admin_pass = "rootpass" }, true);
    defer app.deinit();
    app.loadAdmin();
    const cp = clipper.cp1251;
    const has = struct {
        fn f(body: []const u8, comptime utf8: []const u8) bool {
            return std.mem.indexOf(u8, body, cp.text(utf8)) != null;
        }
    }.f;
    // надписи интерфейса — на языке сборки
    const ui = struct {
        fn f(body: []const u8, comptime ru: []const u8, comptime eng: []const u8) bool {
            return std.mem.indexOf(u8, body, if (clipper.t9n.active) eng else cp.text(ru)) != null;
        }
    }.f;

    // гость не выкладывает; участник с правом write — да
    var guest = Client{ .app = app };
    try testing.expectEqual(@as(u16, 303), (try guest.get(a, "/p/new")).status);
    var vetrov = Client{ .app = app };
    try vetrov.signin(a, "vetrov");
    const form = try vetrov.get(a, "/p/new");
    try testing.expectEqual(@as(u16, 200), form.status);
    try testing.expect(has(form.body, "Фёдор Тютчев"));
    // стих Тютчева (есть в каталоге, № 4)
    var r = try vetrov.send(a, "POST", "/p/new", try formOf(a, &.{ .{ "title", "Весенняя гроза (фрагмент)" }, .{ "author", "4" }, .{ "genre", clipper.t9n.tr("стихи") }, .{ "year", "1828" }, .{ "text", "Люблю грозу в начале мая,\nКогда весенний, первый гром" } }));
    try testing.expectEqual(@as(u16, 303), r.status);
    const poem_id = blk: {
        for (app.snap.pieces) |p| if (std.mem.eql(u8, app.snap.str(p.year), "1828")) break :blk p.id;
        return error.NotFound;
    };
    const poem = try guest.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{poem_id}));
    try testing.expect(has(poem.body, "Люблю грозу"));
    try testing.expect(ui(poem.body, "Выложил:", "Posted by:"));
    try testing.expect(has(poem.body, "Фёдор Тютчев"));
    // песня от нового автора — ChordPro
    r = try vetrov.send(a, "POST", "/p/new", try formOf(a, &.{ .{ "title", "Дорожная" }, .{ "author", "" }, .{ "new_author", "Иван Песенник" }, .{ "years", "1900–1970" }, .{ "genre", clipper.t9n.tr("песня с аккордами") }, .{ "text", "{title: Дорожная}\n[Am]Ночь, бен[Dm]зин и ветер\n{soc}\n[G]Кто за [C]всё\n{eoc}" }, .{ "notes", "X:1\nK:Am\n|A2c|" } }));
    try testing.expectEqual(@as(u16, 303), r.status);
    var song: ?*const clipper.snapshot.Piece = null;
    for (app.snap.pieces) |*p| if (p.id < 0 and p.flags & clipper.snapshot.piece_chordpro != 0) {
        song = p;
    };
    const sg = song.?;
    const song_id = sg.id;
    const author_new = sg.author;
    try testing.expect(author_new > 0);
    try testing.expect(has(app.snap.str(app.snap.person(author_new).?.name), "Иван Песенник"));
    const song_page = try guest.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{sg.id}));
    try testing.expect(std.mem.indexOf(u8, song_page.body, "<table class=\"cp\"") != null);
    try testing.expect(std.mem.indexOf(u8, song_page.body, "<b>Am</b>") != null);
    try testing.expect(std.mem.indexOf(u8, song_page.body, "<blockquote class=\"chorus\">") != null);
    try testing.expect(ui(song_page.body, "Ноты (ABC-нотация)", "Notes (ABC notation)"));
    // песню (отрицательный номер) правит выложивший
    try testing.expectEqual(@as(u16, 200), (try vetrov.get(a, try std.fmt.allocPrint(a, "/p/{d}/edit", .{song_id}))).status);
    // неверно: без текста или автор не из списка — 400
    try testing.expectEqual(@as(u16, 400), (try vetrov.send(a, "POST", "/p/new", try formOf(a, &.{ .{ "title", "x" }, .{ "author", "4" }, .{ "text", "" } }))).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.send(a, "POST", "/p/new", try formOf(a, &.{ .{ "title", "x" }, .{ "author", "999" }, .{ "text", "y" } }))).status);

    // права на правку: выложивший — да; чужой участник — нет; сотрудник — да
    const edit_url = try std.fmt.allocPrint(a, "/p/{d}/edit", .{poem_id});
    try testing.expectEqual(@as(u16, 200), (try vetrov.get(a, edit_url)).status);
    var sam = Client{ .app = app };
    try sam.signin(a, "samovarova");
    try testing.expectEqual(@as(u16, 403), (try sam.get(a, edit_url)).status);
    try testing.expect(!ui((try sam.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{poem_id}))).body, "Править или удалить", "Edit or delete"));
    // /u/0 делает librarian сотрудником; сотрудник привязывает samovarova к Тютчеву
    var admin = Client{ .app = app };
    // /u/0 через обратный прокси на этой же машине: соединение с 127.0.0.1, но вход запрещён
    var proxied = Client{ .app = app, .extra = "X-Forwarded-For: 203.0.113.5\r\n" };
    try testing.expectEqual(@as(u16, 401), (try proxied.send(a, "POST", "/signin", "login=admin&pass=rootpass&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", "/signin", "login=admin&pass=rootpass&_csrf=" ++ Client.csrf)).status);
    {
        // сеанс /u/0, открытый локально, через прокси не действует
        var via = Client{ .app = app, .extra = "Via: 1.1 nginx\r\n" };
        via.cookie = admin.cookie;
        try testing.expectEqual(@as(u16, 303), (try via.get(a, "/panel")).status);
        try testing.expectEqual(@as(u16, 200), (try admin.get(a, "/panel")).status);
    }
    {
        var acc = (clipper.db.Db{ .l = &app.ledger, .s = &app.snap, .a = a }).account("librarian").?;
        acc.rights |= clipper.db.rights.staff;
        (clipper.db.Db{ .l = &app.ledger, .s = &app.snap, .a = a }).putAccount(acc);
    }
    var lib = Client{ .app = app };
    try lib.signin(a, "librarian");
    try testing.expectEqual(@as(u16, 200), (try lib.get(a, edit_url)).status);
    // обычный участник привязывать не может
    try testing.expectEqual(@as(u16, 403), (try sam.send(a, "POST", "/u/-102/authors", "add=4&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try lib.send(a, "POST", "/u/-102/authors", "add=4&_csrf=" ++ Client.csrf)).status);
    const upage = try guest.get(a, "/u/-102");
    try testing.expect(ui(upage.body, "Автор на сайте:", "Author on the site:"));
    const cpage = try guest.get(a, "/c/4");
    try testing.expect(ui(cpage.body, "Это участник сайта:", "This is the site member:"));
    // привязанная samovarova теперь правит стих Тютчева — и удаляет его
    try testing.expectEqual(@as(u16, 200), (try sam.get(a, edit_url)).status);
    r = try sam.send(a, "POST", try std.fmt.allocPrint(a, "/p/{d}/edit", .{poem_id}), try formOf(a, &.{ .{ "title", "Весенняя гроза" }, .{ "author", "4" }, .{ "genre", clipper.t9n.tr("стихи") }, .{ "year", "1828" }, .{ "text", "Люблю грозу в начале мая" } }));
    try testing.expectEqual(@as(u16, 303), r.status);
    try testing.expect(has((try guest.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{poem_id}))).body, "<h2>Весенняя гроза</h2>"));
    // без отметки «да» не удаляется
    try testing.expectEqual(@as(u16, 400), (try sam.send(a, "POST", try std.fmt.allocPrint(a, "/p/{d}/delete", .{poem_id}), "_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try sam.send(a, "POST", try std.fmt.allocPrint(a, "/p/{d}/delete", .{poem_id}), "sure=1&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{poem_id}))).status);
    // отвязка: без keep — список пуст, правка снова закрыта (песню выложил vetrov)
    try testing.expectEqual(@as(u16, 303), (try lib.send(a, "POST", "/u/-102/authors", "_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 0), (clipper.db.Db{ .l = &app.ledger, .s = &app.snap, .a = a }).authorsOf(-102).len);
}

test "сотрудник = /u/0 кроме прав сотрудников; удаление черновика; профили; страница автора; цитаты из стихов" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fixture.prepare(testing.allocator, root, false);
    const app = try App.init(testing.allocator, .{ .root = root, .admin_pass = "rootpass" }, true);
    defer app.deinit();
    app.loadAdmin();
    const cp = clipper.cp1251;
    const ui = struct {
        fn f(body: []const u8, comptime ru: []const u8, comptime eng: []const u8) bool {
            return std.mem.indexOf(u8, body, if (clipper.t9n.active) eng else cp.text(ru)) != null;
        }
    }.f;
    const db = clipper.db.Db{ .l = &app.ledger, .s = &app.snap, .a = a };

    // ── права: /u/0 даёт librarian право «сотрудник»
    var admin = Client{ .app = app };
    try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", "/signin", "login=admin&pass=rootpass&_csrf=" ++ Client.csrf)).status);
    const lib_rights = db.account("librarian").?.rights;
    _ = try admin.send(a, "POST", "/panel/rights", try std.fmt.allocPrint(a, "acc=librarian&r_librarian_forum=1&r_librarian_upload=1&r_librarian_comment=1&r_librarian_write=1&r_librarian_quote=1&r_librarian_staff=1&_csrf={s}", .{Client.csrf}));
    try testing.expect(db.account("librarian").?.rights & clipper.db.rights.staff != 0);
    _ = lib_rights;
    // сотрудник видит панель управления сайтом и меняет функции
    var lib = Client{ .app = app };
    try lib.signin(a, "librarian");
    const panel = try lib.get(a, "/panel");
    try testing.expect(std.mem.indexOf(u8, panel.body, "action=\"/panel/features\"") != null);
    try testing.expect(std.mem.indexOf(u8, panel.body, "action=\"/panel/forums\"") != null);
    const forums_before = db.forums().len;
    _ = try lib.send(a, "POST", "/panel/forums", "kind=forum&title=Lit&about=x&_csrf=" ++ Client.csrf);
    try testing.expectEqual(forums_before + 1, db.forums().len);
    // сотрудник: читателю права меняет, но право «сотрудник» не даёт
    _ = try lib.send(a, "POST", "/panel/rights", "acc=reader&r_reader_forum=1&r_reader_staff=1&_csrf=" ++ Client.csrf);
    const rd = db.account("reader").?;
    try testing.expect(rd.rights & clipper.db.rights.forum != 0 and rd.rights & clipper.db.rights.staff == 0 and rd.rights & clipper.db.rights.comment == 0);
    // себе — ничего не меняет (даже снять «сотрудника» с себя)
    _ = try lib.send(a, "POST", "/panel/rights", "acc=librarian&blocked_librarian=1&_csrf=" ++ Client.csrf);
    const me_acc = db.account("librarian").?;
    try testing.expect(me_acc.rights & clipper.db.rights.staff != 0 and !me_acc.blocked);
    // другого сотрудника — не трогает
    _ = try admin.send(a, "POST", "/panel/rights", "acc=vetrov&r_vetrov_write=1&r_vetrov_quote=1&r_vetrov_staff=1&_csrf=" ++ Client.csrf);
    _ = try lib.send(a, "POST", "/panel/rights", "acc=vetrov&blocked_vetrov=1&_csrf=" ++ Client.csrf);
    try testing.expect(!db.account("vetrov").?.blocked);
    try testing.expect(db.account("vetrov").?.rights & clipper.db.rights.staff != 0);
    // /u/0 снимает «сотрудника» с vetrov
    _ = try admin.send(a, "POST", "/panel/rights", "acc=vetrov&r_vetrov_write=1&r_vetrov_quote=1&_csrf=" ++ Client.csrf);
    try testing.expect(db.account("vetrov").?.rights & clipper.db.rights.staff == 0);

    // ── удаление черновика: перенесённый в книгу — след из книги стирается
    var vet = Client{ .app = app };
    try vet.signin(a, "vetrov");
    _ = try vet.send(a, "POST", "/d", "kind=draft&title=One&text=First+text&_csrf=" ++ Client.csrf);
    _ = try vet.send(a, "POST", "/d", "kind=draft&title=Two&text=Second+text&_csrf=" ++ Client.csrf);
    var d_ids: [2]i32 = undefined;
    var nd: usize = 0;
    for (db.drafts(false)) |d| if (std.mem.eql(u8, d.title, "One") or std.mem.eql(u8, d.title, "Two")) {
        if (nd < 2) d_ids[nd] = d.id;
        nd += 1;
    };
    try testing.expectEqual(@as(usize, 2), nd);
    _ = try vet.send(a, "POST", "/d/merge", try std.fmt.allocPrint(a, "id={d}&id={d}&title=Merged&_csrf={s}", .{ d_ids[0], d_ids[1], Client.csrf }));
    const merged = db.draft(d_ids[0]).?.moved;
    try testing.expect(std.mem.startsWith(u8, merged, "/b/"));
    const book_page0 = try vet.get(a, merged);
    try testing.expect(std.mem.indexOf(u8, book_page0.body, try std.fmt.allocPrint(a, "/d/{d}", .{d_ids[0]})) != null);
    // без «да» — нет; чужой участник — нет; автор — да
    try testing.expectEqual(@as(u16, 400), (try vet.send(a, "POST", try std.fmt.allocPrint(a, "/d/{d}/delete", .{d_ids[0]}), "_csrf=" ++ Client.csrf)).status);
    var sam = Client{ .app = app };
    try sam.signin(a, "samovarova");
    try testing.expectEqual(@as(u16, 403), (try sam.send(a, "POST", try std.fmt.allocPrint(a, "/d/{d}/delete", .{d_ids[0]}), "sure=1&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try vet.send(a, "POST", try std.fmt.allocPrint(a, "/d/{d}/delete", .{d_ids[0]}), "sure=1&_csrf=" ++ Client.csrf)).status);
    try testing.expect(db.draft(d_ids[0]) == null);
    const book_page = try vet.get(a, merged);
    try testing.expectEqual(@as(u16, 200), book_page.status);
    try testing.expect(std.mem.indexOf(u8, book_page.body, try std.fmt.allocPrint(a, "/d/{d}\"", .{d_ids[0]})) == null);
    try testing.expect(std.mem.indexOf(u8, book_page.body, try std.fmt.allocPrint(a, "/d/{d}", .{d_ids[1]})) != null);
    // сотрудник удаляет чужой
    try testing.expectEqual(@as(u16, 303), (try lib.send(a, "POST", try std.fmt.allocPrint(a, "/d/{d}/delete", .{d_ids[1]}), "sure=1&_csrf=" ++ Client.csrf)).status);
    try testing.expect(std.mem.indexOf(u8, (try vet.get(a, merged)).body, try std.fmt.allocPrint(a, "/d/{d}\"", .{d_ids[1]})) == null);

    // ── профиль автора: правит сотрудник; привязанный участник; чужой — нет
    try testing.expectEqual(@as(u16, 403), (try sam.get(a, "/c/4/edit")).status);
    try testing.expectEqual(@as(u16, 200), (try lib.get(a, "/c/4/edit")).status);
    _ = try lib.send(a, "POST", "/u/-102/authors", "add=4&_csrf=" ++ Client.csrf);
    try testing.expectEqual(@as(u16, 200), (try sam.get(a, "/c/4/edit")).status);
    var px: [30 * 40 * 4]u8 = undefined;
    for (&px, 0..) |*b, k| b.* = if (k % 4 == 3) 255 else @intCast((k * 13) % 256);
    const photo = try clipper.png.encode(a, .{ .w = 30, .h = 40, .px = &px });
    const forum_id = blk: {
        for (db.forums()) |f| if (std.mem.eql(u8, f.title, "Lit")) break :blk f.id;
        return error.NotFound;
    };
    var r = try sam.sendMultipart(a, "/c/4/edit", &.{ .{ "name", "Fyodor Tyutchev" }, .{ "years", "1803-1873" }, .{ "about", "Poet" }, .{ "pin", try std.fmt.allocPrint(a, "f{d}", .{forum_id}) } }, "photo", "me.png", photo);
    try testing.expectEqual(@as(u16, 303), r.status);
    const pr = db.profile(4);
    try testing.expect(pr.hash != 0);
    try testing.expectEqual(@as(u16, 30), pr.w);
    // страница автора: имя, фото, обсуждения, стихи; цитат нет
    var guest = Client{ .app = app };
    const ap = try guest.get(a, "/c/4");
    try testing.expect(std.mem.indexOf(u8, ap.body, "Fyodor Tyutchev") != null);
    try testing.expect(std.mem.indexOf(u8, ap.body, "/img/b/") != null);
    try testing.expect(std.mem.indexOf(u8, ap.body, try std.fmt.allocPrint(a, "/f/{d}", .{forum_id})) != null);
    try testing.expect(std.mem.indexOf(u8, ap.body, "/p/3") != null); // Silentium! из заготовки
    try testing.expect(!ui(ap.body, "<h3>Цитаты</h3>", "<h3>Quotes</h3>"));
    // фото переживает пересборку снимка (уборка хранилища его не трогает)
    try app.rebuild();
    try app.rebuild();
    var nb: [24]u8 = undefined;
    try testing.expectEqual(@as(u16, 200), (try guest.get(a, try std.fmt.allocPrint(a, "/img/b/{s}", .{clipper.imgstore.fileName(&nb, pr.hash, @enumFromInt(pr.kind))}))).status);
    // профиль участника: сам себе
    r = try vet.sendMultipart(a, "/u/-101/edit", &.{.{ "about", "Road poet" }}, "photo", "p.png", photo);
    try testing.expectEqual(@as(u16, 303), r.status);
    try testing.expect(db.profile(-101).hash != 0);
    try testing.expectEqual(@as(u16, 403), (try sam.get(a, "/u/-101/edit")).status);

    // ── цитата из стиха (абзац 0 «Silentium!»): приписывается автору
    const poem = try guest.get(a, "/p/3");
    try testing.expect(std.mem.indexOf(u8, poem.body, "id=\"booktext\"") != null and std.mem.indexOf(u8, poem.body, "id=\"p0\"") != null);
    var form = std.ArrayList(u8).init(a);
    try formField(a, &form, "kind", "quote");
    try formField(a, &form, "para", "0");
    try formField(a, &form, "person", "4");
    try formField(a, &form, "text", "Молчи, скрывайся");
    try form.writer().print("&_csrf={s}", .{Client.csrf});
    try testing.expectEqual(@as(u16, 303), (try sam.send(a, "POST", "/p/3/mark", form.items)).status);
    var found = false;
    for (db.quotes()) |q| found = found or (q.src == 'p' and q.book == 3 and q.person == 4);
    try testing.expect(found);
    // повтор — 400; несуществующий абзац — 400
    try testing.expectEqual(@as(u16, 400), (try sam.send(a, "POST", "/p/3/mark", form.items)).status);
    try testing.expectEqual(@as(u16, 400), (try sam.send(a, "POST", "/p/3/mark", "kind=quote&para=99&text=x&_csrf=" ++ Client.csrf)).status);
    // в разделе цитат — ссылка на стих
    const qlist = try guest.get(a, "/c");
    try testing.expect(std.mem.indexOf(u8, qlist.body, "/p/3#p0") != null);
}

test "записи /v: аудиокнига и исполнение, перекодирование в MP3 CBR 128, Range, права, привязка к чтецу" {
    if (!clipper.voice.enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fixture.prepare(testing.allocator, root, false);
    const app = try App.init(testing.allocator, .{ .root = root, .admin_pass = "rootpass" }, true);
    defer app.deinit();
    app.loadAdmin();
    const cp = clipper.cp1251;
    const has = struct {
        fn f(body: []const u8, comptime utf8: []const u8) bool {
            return std.mem.indexOf(u8, body, cp.text(utf8)) != null;
        }
    }.f;
    const audio = clipper.audio;
    // вход: MP3 своего кодера — 1 с синуса, 44,1 кГц, моно
    var src = std.ArrayList(u8).init(a);
    var enc = audio.mp3enc.Encoder.init(src.writer().any(), 44100, 1);
    var buf: [1152]f32 = undefined;
    for (0..39) |f| {
        for (0..1152) |i| buf[i] = 0.4 * @sin(@as(f32, @floatFromInt(f * 1152 + i)) * 0.06);
        try enc.push(&buf, &buf);
    }
    try enc.finish();
    const book_id = app.snap.bookAt(0).id;
    const piece_id = app.snap.pieceAt(0).id;

    var guest = Client{ .app = app };
    try testing.expectEqual(@as(u16, 200), (try guest.get(a, "/v")).status);
    try testing.expectEqual(@as(u16, 303), (try guest.get(a, "/v/new")).status);
    var vetrov = Client{ .app = app };
    try vetrov.signin(a, "vetrov");
    try testing.expectEqual(@as(u16, 200), (try vetrov.get(a, "/v/new")).status);
    const reader_name = try cp.encodeAlloc(a, "Чтец Тестовый");
    const book_s = try std.fmt.allocPrint(a, "{d}", .{book_id});
    const piece_s = try std.fmt.allocPrint(a, "{d}", .{piece_id});
    // аудиокнига: книга есть, чтец новый и «это я»
    var r = try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "book", book_s }, .{ "new_reader", reader_name }, .{ "me", "1" }, .{ "year", "2003" } }, "file", "x.mp3", src.items);
    try testing.expectEqual(@as(u16, 303), r.status);
    const page = try guest.get(a, "/v/1");
    try testing.expectEqual(@as(u16, 200), page.status);
    try testing.expect(has(page.body, "Чтец Тестовый"));
    try testing.expect(std.mem.indexOf(u8, page.body, "/v/1.mp3") != null);
    // файл: MPEG-1 Layer III 128 кбит/с, без ID3v2, с ID3v1
    const mp3 = try guest.get(a, "/v/1.mp3");
    try testing.expectEqual(@as(u16, 200), mp3.status);
    const hd = audio.mp3dec.header(mp3.body).?;
    try testing.expectEqual(@as(u2, 0), hd.ver);
    try testing.expectEqual(@as(u32, 128), hd.bitrate);
    try testing.expectEqual(@as(u32, 44100), hd.rate);
    try testing.expect(std.mem.eql(u8, mp3.body[mp3.body.len - 128 ..][0..3], "TAG"));
    try testing.expect(std.mem.indexOf(u8, mp3.body[mp3.body.len - 128 ..], reader_name) != null);
    var d = try audio.mp3dec.Decoder.init(mp3.body);
    var frames: usize = 0;
    while (d.next() > 0) frames += 1;
    try testing.expect(frames >= 39);
    // диапазон
    {
        var w = std.io.fixedBufferStream(&vetrov.req_buf);
        try w.writer().print("GET /v/1.mp3 HTTP/1.1\r\nHost: test\r\nRange: bytes=10-19\r\n\r\n", .{});
        const req = switch (http.parse(w.getWritten())) {
            .ok => |x| x,
            else => return error.BadRequest,
        };
        var reply = Reply{};
        app.handle(&req, "", clipper.net.loopback, false, &reply);
        defer if (reply.owned) |o| app.gpa.free(o);
        try testing.expectEqual(@as(u16, 206), reply.status);
        try testing.expectEqualSlices(u8, mp3.body[10..20], reply.body);
    }
    // на странице книги — аудиокнига
    try testing.expect(has((try guest.get(a, try std.fmt.allocPrint(a, "/b/{d}", .{book_id}))).body, "Чтец Тестовый"));
    // исполнение стиха тем же чтецом, со своими словами
    r = try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "perf" }, .{ "piece", piece_s }, .{ "reader", "-1" }, .{ "text", "la la la" } }, "file", "y.mp3", src.items);
    try testing.expectEqual(@as(u16, 303), r.status);
    const perf = try guest.get(a, "/v/2");
    try testing.expect(std.mem.indexOf(u8, perf.body, "la la la") != null);
    try testing.expect(std.mem.indexOf(u8, (try guest.get(a, try std.fmt.allocPrint(a, "/p/{d}", .{piece_id}))).body, "/v/2") != null);
    // чтец: его страница со списком записей
    const rp = try guest.get(a, "/v/-1");
    try testing.expectEqual(@as(u16, 200), rp.status);
    try testing.expect(std.mem.indexOf(u8, rp.body, "/v/1") != null and std.mem.indexOf(u8, rp.body, "/v/2") != null);
    // ошибки: нет книги, нет стиха, нет чтеца, нет файла, не звук — 400
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "book", "99999" }, .{ "reader", "-1" } }, "file", "x.mp3", src.items)).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "perf" }, .{ "piece", "99999" }, .{ "reader", "-1" } }, "file", "x.mp3", src.items)).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "book", book_s } }, "file", "x.mp3", src.items)).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "book", book_s }, .{ "reader", "-1" } }, "file", "x.mp3", "")).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "book", book_s }, .{ "reader", "-1" } }, "file", "x.mp3", "not a sound at all")).status);
    // права: чужой участник не правит; привязанный к чтецу — правит
    var sam = Client{ .app = app };
    try sam.signin(a, "samovarova");
    try testing.expectEqual(@as(u16, 403), (try sam.get(a, "/v/1/edit")).status);
    try testing.expectEqual(@as(u16, 403), (try sam.send(a, "POST", "/u/-102/readers", "add=-1&_csrf=" ++ Client.csrf)).status);
    var admin = Client{ .app = app };
    try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", "/signin", "login=admin&pass=rootpass&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", "/u/-102/readers", "add=-1&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 200), (try sam.get(a, "/v/1/edit")).status);
    try testing.expectEqual(@as(u16, 200), (try sam.get(a, "/v/-1/edit")).status);
    try testing.expect(has((try guest.get(a, "/u/-102")).body, "Чтец Тестовый"));
    // удаление: без «да» — 400, с «да» — запись и файл пропадают
    try testing.expectEqual(@as(u16, 400), (try sam.send(a, "POST", "/v/1/delete", "_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try sam.send(a, "POST", "/v/1/delete", "sure=1&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/v/1")).status);
    try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/v/1.mp3")).status);

    // без книги: нужно название; читает сам автор (новый) — чтец заводится и связывается с ним; источник
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "reader", "-1" } }, "file", "x.mp3", src.items)).status);
    try testing.expectEqual(@as(u16, 400), (try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "title", "T" }, .{ "by_author", "1" } }, "file", "x.mp3", src.items)).status);
    const author_name = try cp.encodeAlloc(a, "Автор Чтущий");
    r = try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "book" }, .{ "title", "Rasskaz" }, .{ "new_author", author_name }, .{ "by_author", "1" }, .{ "source", "https://www.habr.com/ru/articles/1/" } }, "file", "z.mp3", src.items);
    try testing.expectEqual(@as(u16, 303), r.status);
    const solo = try guest.get(a, "/v/3");
    try testing.expectEqual(@as(u16, 200), solo.status);
    try testing.expect(has(solo.body, "книги нет"));
    try testing.expect(has(solo.body, "(автор)"));
    try testing.expect(std.mem.indexOf(u8, solo.body, ">habr.com<") != null);
    try testing.expect(has((try guest.get(a, "/v/-2")).body, "Это автор"));
    // привязать позже со страницы книги
    const book_page = try std.fmt.allocPrint(a, "/b/{d}", .{book_id});
    try testing.expect(std.mem.indexOf(u8, (try vetrov.get(a, book_page)).body, "name=\"rec\"") != null);
    try testing.expectEqual(@as(u16, 403), (try sam.send(a, "POST", try std.fmt.allocPrint(a, "/b/{d}/voice", .{book_id}), "rec=3&_csrf=" ++ Client.csrf)).status);
    try testing.expectEqual(@as(u16, 303), (try vetrov.send(a, "POST", try std.fmt.allocPrint(a, "/b/{d}/voice", .{book_id}), "rec=3&_csrf=" ++ Client.csrf)).status);
    try testing.expect(std.mem.indexOf(u8, (try guest.get(a, book_page)).body, "/v/3") != null);
    try testing.expect(!has((try guest.get(a, "/v/3")).body, "книги нет"));
    // исполнение без текста, потом текст выкладывается со страницы записи (?voice=4)
    r = try vetrov.sendMultipart(a, "/v/new", &.{ .{ "kind", "perf" }, .{ "title", "Pesnya" }, .{ "reader", "-1" } }, "file", "w.mp3", src.items);
    try testing.expectEqual(@as(u16, 303), r.status);
    try testing.expect(has((try vetrov.get(a, "/v/4")).body, "выложить текст"));
    try testing.expect(std.mem.indexOf(u8, (try vetrov.get(a, "/p/new?voice=4")).body, "name=\"voice\" value=\"4\"") != null);
    r = try vetrov.send(a, "POST", "/p/new", "title=Pesnya&text=slova&voice=4&source=mrakopedia&_csrf=" ++ Client.csrf);
    try testing.expectEqual(@as(u16, 303), r.status);
    const after = try guest.get(a, "/v/4");
    try testing.expect(!has(after.body, "текста нет"));
    try testing.expect(std.mem.indexOf(u8, after.body, "slova") != null);
    // источник книги правит сотрудник
    try testing.expectEqual(@as(u16, 303), (try admin.send(a, "POST", try std.fmt.allocPrint(a, "/b/{d}/source", .{book_id}), "source=arxiv&_csrf=" ++ Client.csrf)).status);
    try testing.expect(has((try guest.get(a, book_page)).body, "Источник: arxiv"));
    try testing.expectEqual(@as(u16, 403), (try sam.send(a, "POST", try std.fmt.allocPrint(a, "/b/{d}/source", .{book_id}), "source=x&_csrf=" ++ Client.csrf)).status);
}

test "записи /v: -Nv выключает раздел, -Gv открывает гостю только его" {
    if (!clipper.voice.enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fixture.prepare(testing.allocator, root, false);
    {
        const app = try App.init(testing.allocator, .{ .root = root, .sec = .{ .off = S.bit(.v) } }, true);
        defer app.deinit();
        var guest = Client{ .app = app };
        try testing.expectEqual(@as(u16, 404), (try guest.get(a, "/v")).status);
        try testing.expect(!linksTo((try guest.get(a, "/b")).body, 'v'));
    }
    {
        const app = try App.init(testing.allocator, .{ .root = root, .sec = .{ .guest = S.bit(.v), .guest_set = true } }, true);
        defer app.deinit();
        var guest = Client{ .app = app };
        try testing.expectEqual(@as(u16, 200), (try guest.get(a, "/v")).status);
        try testing.expectEqual(@as(u16, 200), (try guest.get(a, "/")).status);
        try testing.expectEqual(@as(u16, 303), (try guest.get(a, "/b")).status);
    }
}
