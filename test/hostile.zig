//! Враждебный ввод (этап 9): разборщики и всё приложение целиком получают
//! случайный и случайно испорченный ввод. Требования: ни паники, ни выхода за
//! границы (сборка тестов — Debug, проверки включены), ни ответа 500, ни
//! утечки памяти (распределитель тестов считает каждое выделение).
//!
//! Зерно случайности постоянное: упавший случай повторяется при каждом запуске.

const std = @import("std");
const clipper = @import("clipper");
const fixture = @import("fixture.zig");
const http = clipper.http;
const Reply = clipper.server.Reply;
const App = clipper.app.App;

const testing = std.testing;

/// Байты, из которых складываются адреса: всё, что значимо для разбора.
const url_alphabet = "/??&&==%%--++..0123456789abcdefxtmbpqcdufes#;:@~_\xd0\x90\xc0\xff";
const head_alphabet = "GETPOSTHEAD /?&=%:;,-.\r\n\t HTTP/1.1HostCookieContent-LengthRangebytes0123456789\x00\x7f\xff";

fn fill(rnd: std.Random, buf: []u8, alphabet: []const u8) void {
    for (buf) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
}

/// Портит `buf[0..len]` на месте: замена, удаление, удвоение, вставка байта.
fn mutate(rnd: std.Random, buf: []u8, len_in: usize, alphabet: []const u8) usize {
    var len = len_in;
    var times = rnd.intRangeAtMost(usize, 1, 4);
    while (times > 0 and len > 0) : (times -= 1) {
        const at = rnd.uintLessThan(usize, len);
        switch (rnd.uintLessThan(u8, 4)) {
            0 => buf[at] = alphabet[rnd.uintLessThan(usize, alphabet.len)],
            1 => {
                std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                len -= 1;
            },
            2 => if (len < buf.len) {
                std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                len += 1;
            },
            else => buf[at] = rnd.int(u8),
        }
    }
    return len;
}

test "разбор запроса: случайный и испорченный ввод" {
    var prng = std.Random.DefaultPrng.init(0x9e3779b9);
    const rnd = prng.random();
    const seeds = [_][]const u8{
        "GET /b/2?t=samlib&m=true HTTP/1.1\r\nHost: x\r\nCookie: sid=abc; csrf=def\r\nRange: bytes=0-99\r\n\r\n",
        "POST /d HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 7\r\n\r\na=1&b=2",
        "HEAD / HTTP/1.0\r\nConnection: keep-alive\r\nIf-None-Match: \"1\"\r\nIf-Modified-Since: x\r\n\r\n",
    };
    var buf: [http.limits.head_bytes + 512]u8 = undefined;
    var ok: usize = 0;
    for (0..60000) |i| {
        var len: usize = undefined;
        if (i % 3 == 0) {
            len = rnd.uintLessThan(usize, if (i % 30 == 0) buf.len else 300);
            fill(rnd, buf[0..len], head_alphabet);
        } else {
            const s = seeds[rnd.uintLessThan(usize, seeds.len)];
            @memcpy(buf[0..s.len], s);
            len = mutate(rnd, &buf, s.len, head_alphabet);
        }
        switch (http.parse(buf[0..len])) {
            .incomplete => try testing.expect(len < http.limits.head_bytes),
            .fail => |st| try testing.expect(st >= 400 and st <= 505),
            .ok => |r| {
                ok += 1;
                try testing.expect(r.head_len <= len and r.head_len <= http.limits.head_bytes);
                try testing.expect(r.path.len > 0 and r.path[0] == '/');
                try testing.expect(r.target.len <= http.limits.target_bytes);
                try testing.expect(r.method == .POST or r.content_length == 0);
                for (r.target) |c| try testing.expect(c > 0x20 and c != 0x7f);
            },
        }
    }
    try testing.expect(ok > 1000); // испорченные запросы не все отвергаются: разбор проверен и на принятых
}

test "формы, диапазоны, адреса: случайный ввод" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const multipart = "--XX\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nT\r\n--XX\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nline1\r\nline2\r\n--XX--\r\n";
    const form_alphabet = "&&==%%++-XX\r\n\"; name=filenameContent-Disposition:form-data0123456789abc\xd0\x90\xff\x00";
    var buf: [1024]u8 = undefined;
    for (0..30000) |i| {
        var len: usize = undefined;
        if (i % 2 == 0) {
            @memcpy(buf[0..multipart.len], multipart);
            len = mutate(rnd, &buf, multipart.len, form_alphabet);
        } else {
            len = rnd.uintLessThan(usize, 400);
            fill(rnd, buf[0..len], form_alphabet);
        }
        const body = buf[0..len];
        if (http.parseForm(a, "multipart/form-data; boundary=XX", body)) |f| {
            for (f.fields) |x| if (x.filename != null) {
                // значение файла — срез тела, а не чего-то за его пределами
                try testing.expect(@intFromPtr(x.value.ptr) >= @intFromPtr(body.ptr) and @intFromPtr(x.value.ptr) + x.value.len <= @intFromPtr(body.ptr) + body.len);
            };
        } else |_| {}
        if (http.parseForm(a, "application/x-www-form-urlencoded", body)) |f| {
            try testing.expect(f.fields.len <= 512);
            _ = f.get("a");
            _ = f.int("0");
        } else |_| {}
        _ = http.parseForm(a, body[0..@min(len, 90)], body) catch {};
        _ = http.param(a, body, "a");
        _ = http.cookie(body, "sid");
        const total = rnd.uintLessThan(u64, 5000);
        if (http.parseRange(body[0..@min(len, 40)], total) catch null) |r| try testing.expect(r[0] < r[1] and r[1] <= total);
        _ = arena.reset(.retain_capacity);
    }
    // диапазоны: строки, похожие на настоящие
    var rb: [48]u8 = undefined;
    for (0..20000) |_| {
        const total = rnd.uintLessThan(u64, 2000);
        const x = rnd.uintLessThan(u64, 3000);
        const y = rnd.uintLessThan(u64, 3000);
        const s = switch (rnd.uintLessThan(u8, 4)) {
            0 => std.fmt.bufPrint(&rb, "bytes={d}-{d}", .{ x, y }) catch unreachable,
            1 => std.fmt.bufPrint(&rb, "bytes={d}-", .{x}) catch unreachable,
            2 => std.fmt.bufPrint(&rb, "bytes=-{d}", .{y}) catch unreachable,
            else => std.fmt.bufPrint(&rb, "bytes={d}-{d}99999999999999999999", .{ x, y }) catch unreachable,
        };
        if (http.parseRange(s, total) catch null) |r| try testing.expect(r[0] < r[1] and r[1] <= total);
    }
}

// ───────────── всё приложение ─────────────

const Visitor = struct {
    app: *App,
    cookie_buf: [160]u8 = undefined,
    cookie: []const u8 = "",
    req_buf: [http.limits.head_bytes]u8 = undefined,
    counts: [600]u32 = [_]u32{0} ** 600,
    rejected: u32 = 0,

    const csrf = "0123456789abcdef0123456789abcdef";

    /// Один запрос через разборщик и приложение. null — запрос отвергнут разбором.
    fn send(v: *Visitor, method: []const u8, target: []const u8, ctype: []const u8, body: []const u8) !?u16 {
        var w = std.io.fixedBufferStream(&v.req_buf);
        w.writer().print("{s} {s} HTTP/1.1\r\nHost: test\r\nCookie: csrf={s}{s}{s}\r\n", .{ method, target, csrf, if (v.cookie.len > 0) "; sid=" else "", v.cookie }) catch return null;
        if (ctype.len > 0) w.writer().print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ ctype, body.len }) catch return null;
        w.writer().writeAll("\r\n") catch return null;
        const req = switch (http.parse(w.getWritten())) {
            .ok => |r| r,
            else => {
                v.rejected += 1;
                return null;
            },
        };
        if (req.content_length > v.app.bodyLimit(&req)) return 413;
        var reply = Reply{};
        v.app.handle(&req, body, clipper.net.loopback, false, &reply);
        defer if (reply.owned) |o| v.app.gpa.free(o);
        if (std.mem.indexOf(u8, reply.extra[0..reply.extra_len], "Set-Cookie: sid=")) |i| {
            const rest = reply.extra[i + 16 .. reply.extra_len];
            const end = std.mem.indexOfAny(u8, rest, ";\r") orelse rest.len;
            @memcpy(v.cookie_buf[0..end], rest[0..end]);
            v.cookie = v.cookie_buf[0..end];
        }
        v.counts[reply.status] += 1;
        // 500 — «страница не поместилась» или сбой хранилища: ни то ни другое
        // посетитель вызвать не должен
        if (reply.status >= 500 and reply.status != 503) {
            std.debug.print("\n{s} {s} → {d}\n{s}\n", .{ method, target, reply.status, body[0..@min(body.len, 400)] });
            return error.ServerError;
        }
        // заголовки ответа — строки без разрывов: иначе их можно подделать
        for (reply.extra[0..reply.extra_len], 0..) |ch, i| {
            if (ch == '\n') try testing.expect(i > 0 and reply.extra[i - 1] == '\r');
            if (ch == '\r') try testing.expect(i + 1 < reply.extra_len and reply.extra[i + 1] == '\n');
        }
        return reply.status;
    }

    fn signin(v: *Visitor, login: []const u8) !void {
        var b: [96]u8 = undefined;
        const body = try std.fmt.bufPrint(&b, "login={s}&pass={s}&_csrf={s}", .{ login, login, csrf });
        v.cookie = "";
        try testing.expectEqual(@as(?u16, 303), try v.send("POST", "/signin", "application/x-www-form-urlencoded", body));
        try testing.expect(v.cookie.len > 0);
    }
};

const get_seeds = [_][]const u8{
    "/",                 "/help",            "/s?q=%D2%E0%EC%E0%ED%FC", "/s?q=a",         "/p",          "/p/1",         "/p/-1",
    "/b",                "/b/2",             "/b/0",                    "/b/-1",          "/b/2/1",      "/b/2/3",       "/b/0/7",
    "/b/2/-1",           "/b/2/-1-2",        "/b/2/txt",                "/b/2/fb2",       "/b/2/epub",   "/b/2/txt?cs=1251", "/b/upload",
    "/q/2",              "/q/2?ch=2",        "/c",                      "/c/2",           "/c/-2",       "/c/2?op=a&ed=b&sz=3", "/d",
    "/d/1",              "/d/-1",            "/f",                      "/f/1",           "/f/1?topic=1", "/f/lit",      "/f/lit?th=5",
    "/u",                "/u/0",             "/u/1001",                 "/u/-101",        "/signin?back=/b/2", "/signup", "/logout",
    "/panel",            "/bookmarks",       "/e",                      "/e/b/2?ch=3",    "/e/p/2",      "/e/c/-3?op=a&sz=2", "/e/d/1",
    "/e/u/-101",         "/e/f/1",           "/e/stat",                 "/e/banner?size=468", "/x/b/reads.svg?id=2", "/x/b/comments.png?id=2", "/x/u/books?id=-101&label=a&color=blue",
    "/x/s/p.svg?label=poems&color=maroon", "/x/site/users", "/css/flibusta-dark.css", "/css/nepomn-time.css", "/g/91/83a5c9-abcbef.bmp", "/img/000000000000", "/files/a/b.txt",
    "/theme?url=/b/2&t=samlib", "/?t=nepomn&m=true", "/b/2/1?t=proza-dark&m=false", "/favicon.ico", "/logo64.png", "/nope", "/a/b/c/d/e/f/g",
};

const post_seeds = [_][]const u8{
    "/d",            "/d/1/piece",    "/d/1/book",    "/d/2/piece",     "/d/book",       "/b/2/comment", "/b/0/comment",
    "/b/2/1/mark",   "/b/2/2/mark",   "/b/0/1/mark",  "/bookmarks/del", "/bookmarks/note", "/c/new",     "/c/-1/books",
    "/c/-3/books",   "/f/1/topic",    "/f/1/reply",   "/f/3/topic",     "/f/lit/post",   "/f/b/post",    "/f/zz/post",
    "/signin",       "/panel/pass",   "/panel/about", "/panel/features", "/panel/rights", "/panel/x",    "/b/upload",
    "/nope",         "/",             "/logout/x",    "/signup/x",
};

const field_names = [_][]const u8{
    "title", "text",  "kind", "para", "person", "id",    "note", "parent", "topic", "name", "author", "book", "about", "tags",
    "login", "pass",  "nick", "back", "t",      "m",     "op",   "ed",     "sz",    "th",   "ch",     "old",  "new",   "ids",
    "embed", "file",  "pic",  "q",    "url",    "label", "ttl",  "draft",  "d",     "page", "from",   "to",
};

fn value(rnd: std.Random, w: *std.ArrayList(u8)) !void {
    switch (rnd.uintLessThan(u8, 12)) {
        0 => try w.writer().print("{d}", .{rnd.intRangeAtMost(i32, -5, 9)}),
        1 => try w.writer().print("{d}", .{rnd.int(i64)}),
        2 => try w.appendSlice("99999999999999999999999"),
        3 => try w.appendSlice("%D0%AF+%D0%B5%D1%85%D0%B0%D0%BB"), // «Я ехал» — есть в книге 2
        4 => try w.appendSlice("%FF%FE%00%0D%0A%3Cscript%3E%22%27%26"),
        5 => try w.appendSlice("quote"),
        6 => try w.appendSlice("bookmark"),
        7 => try w.appendSlice("%2F%2Fevil.example%0D%0ASet-Cookie%3A+x%3D1"),
        8 => {
            const n = rnd.uintLessThan(usize, 6000);
            // длинный текст: абзацы, строки «## глава», кириллица
            for (0..n) |i| try w.appendSlice(if (i % 61 == 60) "%0A%0A%23%23+" else if (i % 7 == 0) "%C0" else "a");
        },
        9 => {},
        10 => try w.appendSlice("draft"),
        else => {
            var raw: [24]u8 = undefined;
            fill(rnd, &raw, url_alphabet);
            for (raw) |c| if (c != '&' and c != '#') try w.append(c);
        },
    }
}

test "приложение: случайные адреса и формы не роняют сервер и не дают 500" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try fixture.prepare(testing.allocator, root, false);

    const app = try App.init(testing.allocator, .{ .root = root }, true);
    defer app.deinit();
    var prng = std.Random.DefaultPrng.init(2003);
    const rnd = prng.random();

    var guest = Visitor{ .app = app };
    var reader = Visitor{ .app = app };
    var author = Visitor{ .app = app };
    try reader.signin("reader");
    try author.signin("vetrov");
    const visitors = [_]*Visitor{ &guest, &reader, &author };

    // 1. чтение: настоящие адреса, испорченные адреса, случайные адреса
    var target: [600]u8 = undefined;
    for (get_seeds) |s| for (visitors) |v| {
        _ = try v.send("GET", s, "", "");
        _ = try v.send("HEAD", s, "", "");
    };
    for (0..6000) |i| {
        var len: usize = undefined;
        if (i % 5 == 0) {
            target[0] = '/';
            len = 1 + rnd.uintLessThan(usize, if (i % 50 == 0) target.len - 1 else 60);
            fill(rnd, target[1..len], url_alphabet);
        } else {
            const s = get_seeds[rnd.uintLessThan(usize, get_seeds.len)];
            @memcpy(target[0..s.len], s);
            len = mutate(rnd, &target, s.len, url_alphabet);
        }
        const v = visitors[rnd.uintLessThan(usize, visitors.len)];
        _ = try v.send(if (i % 7 == 0) "HEAD" else "GET", target[0..len], "", "");
        if (i % 500 == 0) app.tick(app.now + @as(i64, @intCast(i)));
    }

    // 2. запись: формы со случайными полями; токен CSRF настоящий, иначе
    // дальше проверки токена ничего не выполняется
    var body = std.ArrayList(u8).init(testing.allocator);
    defer body.deinit();
    for (0..2500) |i| {
        const s = post_seeds[rnd.uintLessThan(usize, post_seeds.len)];
        @memcpy(target[0..s.len], s);
        const len = if (i % 4 == 0) mutate(rnd, &target, s.len, "0123456789-/") else s.len;
        body.clearRetainingCapacity();
        if (i % 9 != 0) try body.appendSlice("_csrf=" ++ Visitor.csrf);
        for (0..rnd.uintLessThan(usize, 7)) |_| {
            try body.append('&');
            try body.appendSlice(field_names[rnd.uintLessThan(usize, field_names.len)]);
            try body.append('=');
            try value(rnd, &body);
        }
        const v = visitors[rnd.uintLessThan(usize, visitors.len)];
        if (body.items.len > http.limits.form_body) continue;
        _ = try v.send("POST", target[0..len], "application/x-www-form-urlencoded", body.items);
        // форма могла закончить сеанс (смена пароля, «выйти везде»)
        if (v != &guest and try v.send("GET", "/bookmarks", "", "") == 303) try v.signin(if (v == &reader) "reader" else "vetrov");
    }

    // 3. загрузки: испорченные FB2, текст и картинки в multipart
    const fb2 = "<?xml version=\"1.0\" encoding=\"utf-8\"?><FictionBook><description><title-info><book-title>Проба</book-title><annotation><p>А.</p></annotation></title-info></description><body><section><title><p>Один</p></title><p>Текст первой главы.</p></section><section><p>Вторая.</p><poem><stanza><v>стих</v></stanza></poem></section></body></FictionBook>";
    const xml_alphabet = "<>/&;#\"='p vsectionbodytitle!-[]CDATA\r\n\xd0\x90\xff\x00";
    var file_buf: [1024]u8 = undefined;
    for (0..120) |i| {
        var flen: usize = undefined;
        if (i % 3 == 2) {
            flen = rnd.uintLessThan(usize, file_buf.len);
            rnd.bytes(file_buf[0..flen]);
        } else {
            @memcpy(file_buf[0..fb2.len], fb2);
            flen = if (i == 0) fb2.len else mutate(rnd, &file_buf, fb2.len, xml_alphabet);
        }
        const file = file_buf[0..flen];
        if (std.mem.indexOf(u8, file, "--BND") != null) continue;
        const board = i % 2 == 1;
        body.clearRetainingCapacity();
        try body.writer().print("--BND\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n--BND\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nT{d}\r\n--BND\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\n{s}\r\n--BND\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{
            Visitor.csrf, i, if (i % 4 == 0) "" else "x", if (board) "pic" else "file", if (board) "a.png" else if (i % 5 == 0) "a.txt" else "a.fb2",
        });
        try body.appendSlice(file);
        try body.appendSlice("\r\n--BND--\r\n");
        _ = try author.send("POST", if (board) "/f/lit/post" else "/b/upload", "multipart/form-data; boundary=BND", body.items);
        _ = try guest.send("GET", "/b", "", "");
    }
    // после всего сайт цел: главная и каталог открываются, новые книги читаются
    try testing.expectEqual(@as(?u16, 200), try guest.send("GET", "/", "", ""));
    try testing.expectEqual(@as(?u16, 200), try guest.send("GET", "/b", "", ""));
    for (1..40) |id| {
        var t: [32]u8 = undefined;
        for ([_][]const u8{ "", "/1", "/txt", "/fb2", "/epub" }) |tail| {
            _ = try guest.send("GET", try std.fmt.bufPrint(&t, "/b/{d}{s}", .{ id, tail }), "", "");
        }
    }

    var answered: u32 = 0;
    var kinds: u32 = 0;
    for (visitors) |v| for (v.counts) |n| {
        answered += n;
        if (n > 0) kinds += 1;
    };
    // ввод не просто отвергается у входа: видны и страницы, и отказы, и переадресации
    try testing.expect(answered > 8000);
    try testing.expect(guest.counts[200] > 500 and guest.counts[404] > 500 and reader.counts[303] > 50 and author.counts[200] > 500);
}
