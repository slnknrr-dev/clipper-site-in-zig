//! Скачивание книги: txt (UTF-8 или windows-1251 по `?cs=`), fb2 (XML) и
//! epub (свой ZIP, deflate из std). Всё собирается на лету из кадров снимка.

const std = @import("std");
const fb2mod = @import("fb2.zig");
const t9n = @import("t9n.zig");
const cp = @import("cp1251.zig");
const http = @import("http.zig");
const snapshot = @import("snapshot.zig");
const route = @import("route.zig");
const Ctx = @import("app.zig").Ctx;

const T = cp.text;
const Out = std.ArrayList(u8);

/// Текст в windows-1251 → UTF-8 с экранированием XML; `br` — чем заменить перевод строки.
fn xml(out: *Out, text: []const u8, br: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice("&amp;"),
        '<' => try out.appendSlice("&lt;"),
        '>' => try out.appendSlice("&gt;"),
        '"' => try out.appendSlice("&quot;"),
        '\n' => try out.appendSlice(br),
        else => {
            var b: [3]u8 = undefined;
            try out.appendSlice(b[0..cp.toUtf8(&b, &[1]u8{ch})]);
        },
    };
}

/// Абзацы `<p>…</p>`; одиночный перевод строки внутри — `<br/>`.
fn paras(out: *Out, text: []const u8) !void {
    var it = std.mem.splitSequence(u8, text, "\n\n");
    var first = true;
    while (it.next()) |p| {
        if (fb2mod.imageOf(p) != null) continue; // картинки в выгрузку не идут
        if (!first) try out.append('\n');
        first = false;
        try out.appendSlice("<p>");
        try xml(out, p, "<br/>");
        try out.appendSlice("</p>");
    }
}

fn utf8(out: *Out, text: []const u8, crlf: bool) !void {
    for (text) |ch| {
        if (ch == '\n' and crlf) {
            try out.appendSlice("\r\n");
            continue;
        }
        var b: [3]u8 = undefined;
        try out.appendSlice(b[0..cp.toUtf8(&b, &[1]u8{ch})]);
    }
}

const Book = struct {
    c: *Ctx,
    b: *const snapshot.Book,
    title: []const u8,
    author: []const u8,
    annotation: []const u8,

    fn pageTitle(k: Book, i: usize) []const u8 {
        return k.c.db.s.str(k.c.db.s.bookPages(k.b)[i].title);
    }
    /// Текст страницы; место в арене возвращается вызовом `done`.
    fn pageText(k: Book, i: usize) ![]const u8 {
        return k.c.app.pageText(k.c.a, k.b, i);
    }
    fn done(k: Book, text: []const u8) void {
        k.c.a.free(text);
    }
};

fn txt(out: *Out, k: Book, cp1251: bool) !void {
    var plain = Out.init(out.allocator);
    defer plain.deinit();
    try plain.writer().print("{s}\n{s}\n\n{s}\n\n", .{ k.title, k.author, k.annotation });
    for (0..k.b.n_pages) |i| {
        if (i > 0) try plain.appendSlice("\n\n\n");
        const text = try k.pageText(i);
        defer k.done(text);
        try plain.writer().print("{s}\n\n", .{k.pageTitle(i)});
        var pit = std.mem.splitSequence(u8, text, "\n\n");
        var first = true;
        while (pit.next()) |p| {
            if (fb2mod.imageOf(p) != null) continue;
            if (!first) try plain.appendSlice("\n\n");
            first = false;
            try plain.appendSlice(p);
        }
    }
    if (cp1251) {
        for (plain.items) |ch| if (ch == '\n') try out.appendSlice("\r\n") else try out.append(ch);
    } else try utf8(out, plain.items, true);
}

fn fb2(out: *Out, k: Book) !void {
    const sp = std.mem.indexOfScalar(u8, k.author, ' ') orelse k.author.len;
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<FictionBook xmlns=\"http://www.gribuser.ru/xml/fictionbook/2.0\" xmlns:l=\"http://www.w3.org/1999/xlink\">\n<description><title-info><genre>prose</genre><author><first-name>");
    try xml(out, k.author[0..sp], " ");
    try out.appendSlice("</first-name><last-name>");
    try xml(out, std.mem.trim(u8, k.author[sp..], " "), " ");
    try out.appendSlice("</last-name></author>\n<book-title>");
    try xml(out, k.title, " ");
    try out.appendSlice("</book-title><annotation>");
    try paras(out, k.annotation);
    var date: [10]u8 = undefined;
    try out.writer().print(t9n.tr("</annotation><lang>ru</lang></title-info>\n<document-info><author><nickname>clipper</nickname></author><program-used>Клиппер</program-used><date>{s}</date><id>clipper-book-{d}</id><version>1.0</version></document-info></description>\n<body><title><p>"), .{ http.isoDate(&date, k.c.app.now), k.b.id });
    try xml(out, k.title, " ");
    try out.appendSlice("</p></title>\n");
    for (0..k.b.n_pages) |i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice("<section><title><p>");
        try xml(out, k.pageTitle(i), " ");
        try out.appendSlice("</p></title>\n");
        const text = try k.pageText(i);
        defer k.done(text);
        try paras(out, text);
        try out.appendSlice("</section>");
    }
    try out.appendSlice("\n</body></FictionBook>");
}

// ───────────── zip ─────────────

pub const Zip = struct {
    out: *Out,
    central: Out,
    count: u16 = 0,

    pub fn init(out: *Out) Zip {
        return .{ .out = out, .central = Out.init(out.allocator) };
    }

    pub fn deinit(z: *Zip) void {
        z.central.deinit();
    }

    /// Добавляет файл; `store` — без сжатия (так требуется для `mimetype` в epub).
    pub fn add(z: *Zip, name: []const u8, data: []const u8, store: bool) !void {
        const off: u32 = @intCast(z.out.items.len);
        const crc = std.hash.Crc32.hash(data);
        var packed_buf = Out.init(z.out.allocator);
        defer packed_buf.deinit();
        var method: u16 = 0;
        var body = data;
        if (!store and data.len > 0) {
            var in = std.io.fixedBufferStream(data);
            try std.compress.flate.compress(in.reader(), packed_buf.writer(), .{});
            if (packed_buf.items.len < data.len) {
                method = 8;
                body = packed_buf.items;
            }
        }
        var h: [30]u8 = [_]u8{0} ** 30;
        std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, h[4..6], 20, .little);
        std.mem.writeInt(u16, h[6..8], 0x0800, .little); // имена в UTF-8
        std.mem.writeInt(u16, h[8..10], method, .little);
        std.mem.writeInt(u16, h[12..14], 0x21, .little); // 1980-01-01
        std.mem.writeInt(u32, h[14..18], crc, .little);
        std.mem.writeInt(u32, h[18..22], @intCast(body.len), .little);
        std.mem.writeInt(u32, h[22..26], @intCast(data.len), .little);
        std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
        try z.out.appendSlice(&h);
        try z.out.appendSlice(name);
        try z.out.appendSlice(body);
        var ch: [46]u8 = [_]u8{0} ** 46;
        std.mem.writeInt(u32, ch[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, ch[4..6], 20, .little);
        std.mem.writeInt(u16, ch[6..8], 20, .little);
        std.mem.writeInt(u16, ch[8..10], 0x0800, .little);
        std.mem.writeInt(u16, ch[10..12], method, .little);
        std.mem.writeInt(u16, ch[14..16], 0x21, .little);
        std.mem.writeInt(u32, ch[16..20], crc, .little);
        std.mem.writeInt(u32, ch[20..24], @intCast(body.len), .little);
        std.mem.writeInt(u32, ch[24..28], @intCast(data.len), .little);
        std.mem.writeInt(u16, ch[28..30], @intCast(name.len), .little);
        std.mem.writeInt(u32, ch[42..46], off, .little);
        try z.central.appendSlice(&ch);
        try z.central.appendSlice(name);
        z.count += 1;
    }

    pub fn finish(z: *Zip) !void {
        const off: u32 = @intCast(z.out.items.len);
        try z.out.appendSlice(z.central.items);
        var e: [22]u8 = [_]u8{0} ** 22;
        std.mem.writeInt(u32, e[0..4], 0x06054b50, .little);
        std.mem.writeInt(u16, e[8..10], z.count, .little);
        std.mem.writeInt(u16, e[10..12], z.count, .little);
        std.mem.writeInt(u32, e[12..16], @intCast(z.central.items.len), .little);
        std.mem.writeInt(u32, e[16..20], off, .little);
        try z.out.appendSlice(&e);
    }
};

fn xhtmlOpen(f: *Out, title: []const u8) !void {
    f.clearRetainingCapacity();
    try f.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>");
    try xml(f, title, " ");
    try f.appendSlice("</title></head><body>");
}

fn epub(out: *Out, k: Book) !void {
    var z = Zip.init(out);
    defer z.deinit();
    var f = Out.init(out.allocator);
    defer f.deinit();
    var name_buf: [40]u8 = undefined;
    const n = k.b.n_pages;
    try z.add("mimetype", "application/epub+zip", true);
    try z.add("META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>", false);

    try f.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"bid\" version=\"2.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<dc:title>");
    try xml(&f, k.title, " ");
    try f.appendSlice("</dc:title><dc:creator>");
    try xml(&f, k.author, " ");
    try f.writer().print("</dc:creator><dc:language>ru</dc:language><dc:identifier id=\"bid\">urn:clipper:book:{d}</dc:identifier></metadata>\n<manifest><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"title\" href=\"title.xhtml\" media-type=\"application/xhtml+xml\"/>\n", .{k.b.id});
    for (1..n + 1) |i| try f.writer().print("<item id=\"c{d}\" href=\"c{d}.xhtml\" media-type=\"application/xhtml+xml\"/>", .{ i, i });
    try f.appendSlice("</manifest>\n<spine toc=\"ncx\"><itemref idref=\"title\"/>");
    for (1..n + 1) |i| try f.writer().print("<itemref idref=\"c{d}\"/>", .{i});
    try f.appendSlice("</spine></package>");
    try z.add("OEBPS/content.opf", f.items, false);

    f.clearRetainingCapacity();
    try f.writer().print("<?xml version=\"1.0\" encoding=\"utf-8\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"urn:clipper:book:{d}\"/></head>\n<docTitle><text>", .{k.b.id});
    try xml(&f, k.title, " ");
    try f.appendSlice("</text></docTitle><navMap>");
    for (0..n) |i| {
        try f.writer().print("<navPoint id=\"n{d}\" playOrder=\"{d}\"><navLabel><text>", .{ i + 1, i + 1 });
        try xml(&f, k.pageTitle(i), " ");
        try f.writer().print("</text></navLabel><content src=\"c{d}.xhtml\"/></navPoint>", .{i + 1});
    }
    try f.appendSlice("</navMap></ncx>");
    try z.add("OEBPS/toc.ncx", f.items, false);

    try xhtmlOpen(&f, k.title);
    try f.appendSlice("<h1>");
    try xml(&f, k.title, " ");
    try f.appendSlice("</h1><h2>");
    try xml(&f, k.author, " ");
    try f.appendSlice("</h2>");
    try paras(&f, k.annotation);
    try f.appendSlice("</body></html>");
    try z.add("OEBPS/title.xhtml", f.items, false);

    for (0..n) |i| {
        try xhtmlOpen(&f, k.pageTitle(i));
        try f.appendSlice("<h2>");
        try xml(&f, k.pageTitle(i), " ");
        try f.appendSlice("</h2>");
        const text = try k.pageText(i);
        defer k.done(text);
        try paras(&f, text);
        try f.appendSlice("</body></html>");
        try z.add(std.fmt.bufPrint(&name_buf, "OEBPS/c{d}.xhtml", .{i + 1}) catch unreachable, f.items, false);
    }
    try z.finish();
}

/// /b/N/{txt,fb2,epub}
pub fn download(c: *Ctx, id: i32, fmt: []const u8) void {
    const s = c.db.s;
    const b = s.book(id) orelse return c.notFound();
    if (!c.featureOpen(.downloads)) return c.denied(T("Скачивание отключено."));
    const k = Book{ .c = c, .b = b, .title = s.str(b.title), .author = c.db.name(b.author), .annotation = s.str(b.annotation) };
    // Файл может быть больше арены запроса: он собирается в куче и уходит с ответом.
    var out = Out.init(c.app.gpa);
    const cp1251 = std.ascii.indexOfIgnoreCase(c.q("cs"), "1251") != null;
    const is_txt = std.mem.eql(u8, fmt, "txt");
    const is_fb2 = std.mem.eql(u8, fmt, "fb2");
    (if (is_txt) txt(&out, k, cp1251) else if (is_fb2) fb2(&out, k) else epub(&out, k)) catch {
        out.deinit();
        return c.fail(500, T("Файл не собран."));
    };
    const bytes = out.toOwnedSlice() catch {
        out.deinit();
        return c.fail(500, T("Файл не собран."));
    };
    if (c.req.range.len == 0) c.app.countRead(id, true);
    c.reply.owned = bytes;
    c.reply.header("Content-Disposition: attachment; filename=\"clipper-{d}.{s}\"", .{ id, fmt });
    route.ranged(c, if (is_txt) (if (cp1251) "text/plain; charset=windows-1251" else "text/plain; charset=utf-8") else if (is_fb2) "application/x-fictionbook+xml; charset=utf-8" else "application/epub+zip", bytes);
}

test "zip читается std.zip" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    var z = Zip.init(&out);
    defer z.deinit();
    try z.add("mimetype", "application/epub+zip", true);
    const long = "абзац текста, который хорошо сжимается. " ** 50;
    try z.add("OEBPS/c1.xhtml", long, false);
    try z.finish();
    try std.testing.expectEqualStrings("mimetype", out.items[30..38]);
    try std.testing.expectEqualStrings("application/epub+zip", out.items[38..58]);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.zip", .data = out.items });
    var file = try tmp.dir.openFile("t.zip", .{});
    defer file.close();
    try std.zip.extract(tmp.dir, file.seekableStream(), .{});
    const got = try tmp.dir.readFileAlloc(a, "OEBPS/c1.xhtml", 1 << 20);
    defer a.free(got);
    try std.testing.expectEqualStrings(long, got);
}
