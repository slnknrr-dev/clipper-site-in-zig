//! EPUB → книга. Архив ZIP: `META-INF/container.xml` называет файл OPF, в нём
//! описание (название, автор, аннотация), список файлов и порядок чтения
//! (spine). Каждый документ XHTML порядка чтения становится текстом; новая
//! глава начинается с документа и с каждого заголовка h1–h3 внутри него.
//!
//! Картинки (<img src>, <image href> внутри SVG) становятся абзацами-метками
//! текста, как в FB2 (fb2.imageMark), обложка — из OPF (meta cover или
//! properties="cover-image"). Стили и шрифты не читаются. Защищённые (DRM)
//! книги не открываются: их документы зашифрованы и текста не дают.

const std = @import("std");
const cp = @import("../cp1251.zig");
const common = @import("common.zig");
const fb2 = @import("../fb2.zig");

const Parsed = fb2.Parsed;
const Chapter = fb2.Chapter;
const SrcImage = fb2.SrcImage;
const Text = common.Text;
const Budget = common.Budget;

pub const Error = common.Error || error{ NotEpub, Protected };

const max_chapters = 20000;
const max_documents = 5000;

/// Куски разметки по порядку: текст между тегами и сами теги (без скобок).
const Markup = struct {
    s: []const u8,
    i: usize = 0,

    const Piece = union(enum) { text: []const u8, tag: []const u8 };

    fn next(m: *Markup) ?Piece {
        while (m.i < m.s.len) {
            if (m.s[m.i] != '<') {
                const end = std.mem.indexOfScalarPos(u8, m.s, m.i, '<') orelse m.s.len;
                defer m.i = end;
                return .{ .text = m.s[m.i..end] };
            }
            const rest = m.s[m.i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                m.i = if (std.mem.indexOfPos(u8, m.s, m.i + 4, "-->")) |e| e + 3 else m.s.len;
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, m.s, m.i + 9, "]]>") orelse m.s.len;
                defer m.i = @min(m.s.len, end + 3);
                return .{ .text = m.s[m.i + 9 .. end] };
            } else {
                const end = std.mem.indexOfScalarPos(u8, m.s, m.i + 1, '>') orelse m.s.len;
                defer m.i = @min(m.s.len, end + 1);
                const tag = m.s[m.i + 1 .. end];
                if (tag.len == 0 or tag[0] == '?' or tag[0] == '!') continue;
                return .{ .tag = tag };
            }
        }
        return null;
    }
};

fn isUtf8(doc: []const u8) bool {
    const head = doc[0..@min(doc.len, 200)];
    if (std.ascii.indexOfIgnoreCase(head, "encoding=\"windows-1251\"") != null or std.ascii.indexOfIgnoreCase(head, "encoding='windows-1251'") != null) return false;
    return true;
}

fn oneOf(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

const Book = struct {
    a: std.mem.Allocator,
    budget: *Budget,
    chapters: std.ArrayListUnmanaged(Chapter) = .{},
    body: Text,
    title: []const u8 = "",
    unknown: usize = 0,
    zip: *const common.Zip,
    images: std.ArrayListUnmanaged(SrcImage) = .{},
    /// путь в архиве → номер картинки (одна картинка — один номер)
    seen: std.StringHashMapUnmanaged(u32) = .{},

    /// Номер картинки по пути в архиве; null — нет файла или их слишком много.
    fn image(b: *Book, path: []const u8, caption: []const u8) Error!?u32 {
        if (b.seen.get(path)) |k| return k;
        if (b.images.items.len >= fb2.max_images) return null;
        const entry = b.zip.find(path) orelse return null;
        const bytes = b.zip.read(b.a, entry, b.budget) catch |err| switch (err) {
            error.Damaged => return null,
            else => |e| return e,
        };
        const k: u32 = @intCast(b.images.items.len);
        try b.images.append(b.a, .{ .bytes = bytes, .caption = caption });
        try b.seen.put(b.a, path, k);
        return k;
    }

    /// Метка картинки отдельным абзацем.
    fn mark(b: *Book, k: u32) Error!void {
        try b.body.para();
        var mb: [16]u8 = undefined;
        try b.body.buf.appendSlice(b.a, fb2.imageMark(&mb, k));
        b.body.space = false;
        try b.body.para();
    }

    fn flush(b: *Book) Error!void {
        b.unknown += b.body.unknown;
        b.body.unknown = 0;
        const text = b.body.take();
        defer b.title = "";
        if (text.len == 0) return;
        if (b.chapters.items.len >= max_chapters) return error.TooBig;
        const title = if (b.title.len > 0) b.title[0..@min(b.title.len, 200)] else try std.fmt.allocPrint(b.a, cp.text("Глава {d}"), .{b.chapters.items.len + 1});
        try b.chapters.append(b.a, .{ .title = title, .text = text });
    }

    /// Один документ порядка чтения; `dir` — его папка в архиве (для ссылок на картинки).
    fn document(b: *Book, doc: []const u8, dir: []const u8) Error!void {
        try b.flush();
        const utf8 = isUtf8(doc);
        var m = Markup{ .s = doc };
        var skip: usize = 0; // внутри head, script, style
        var heading: ?Text = null;
        while (m.next()) |piece| switch (piece) {
            .text => |s| {
                if (skip > 0) continue;
                if (heading) |*h| try h.markup(s, utf8) else try b.body.markup(s, utf8);
            },
            .tag => |tag| {
                const closing = tag[0] == '/';
                const self_closing = tag[tag.len - 1] == '/';
                const name = common.tagName(tag);
                // картинка: <img src> или <image href> (в том числе внутри svg обложки)
                if (!closing and heading == null and (oneOf(name, &.{"img"}) and skip == 0 or std.ascii.eqlIgnoreCase(name, "image"))) {
                    const href = common.attr(tag, "src") orelse common.attr(tag, "xlink:href") orelse common.attr(tag, "href");
                    if (href) |h| if (!std.mem.startsWith(u8, h, "data:") and std.mem.indexOf(u8, h, "://") == null) {
                        var cap: []const u8 = "";
                        if (common.attr(tag, "alt")) |alt| {
                            var t = Text{ .a = b.a, .budget = b.budget };
                            try t.markup(alt, utf8);
                            cap = t.take();
                        }
                        var ht = Text{ .a = b.a, .budget = b.budget };
                        try ht.markup(h, false);
                        if (try b.image(try resolve(b.a, dir, ht.take()), cap)) |k| try b.mark(k);
                    };
                    continue;
                }
                if (oneOf(name, &.{ "head", "script", "style", "svg", "nav" })) {
                    if (closing) skip -|= 1 else if (!self_closing) skip += 1;
                } else if (skip > 0) {
                    continue;
                } else if (oneOf(name, &.{ "h1", "h2", "h3" })) {
                    if (!closing and heading == null) {
                        // заголовок после текста — новая глава; заголовок сразу за заголовком — одна
                        if (b.body.len() > 0) try b.flush();
                        heading = Text{ .a = b.a, .budget = b.budget };
                    } else if (closing) if (heading) |*h| {
                        const t = h.take();
                        heading = null;
                        if (t.len > 0) b.title = if (b.title.len > 0) try std.fmt.allocPrint(b.a, "{s}. {s}", .{ b.title, t }) else t;
                    };
                } else if (std.ascii.eqlIgnoreCase(name, "br")) {
                    if (heading) |*h| try h.byte(' ') else try b.body.line();
                } else if (oneOf(name, &.{ "p", "div", "li", "tr", "blockquote", "section", "article", "table", "ul", "ol", "dd", "dt", "pre", "h4", "h5", "h6", "hr", "body", "figure", "figcaption", "aside" })) {
                    if (heading == null) try b.body.para();
                } else if (oneOf(name, &.{ "td", "th" })) {
                    if (heading == null) try b.body.byte(' ');
                }
            },
        };
        try b.body.para();
    }
};

/// Путь внутри архива: папка OPF + ссылка, без «#…», с раскрытыми `%XX` и `..`.
fn resolve(a: std.mem.Allocator, base: []const u8, href_raw: []const u8) Error![]const u8 {
    var href = href_raw;
    if (std.mem.indexOfScalar(u8, href, '#')) |h| href = href[0..h];
    var joined = std.ArrayList(u8).init(a);
    if (href.len == 0 or href[0] != '/') {
        try joined.appendSlice(base);
        if (base.len > 0) try joined.append('/');
    }
    var i: usize = 0;
    while (i < href.len) : (i += 1) {
        if (href[i] == '%' and i + 2 < href.len) {
            if (std.fmt.parseInt(u8, href[i + 1 .. i + 3], 16)) |c| {
                try joined.append(c);
                i += 2;
                continue;
            } else |_| {}
        }
        try joined.append(href[i]);
    }
    var parts = std.ArrayList([]const u8).init(a);
    var it = std.mem.tokenizeAny(u8, joined.items, "/\\");
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
            continue;
        }
        try parts.append(p);
    }
    return try std.mem.join(a, "/", parts.items);
}

/// Убирает теги из уже раскодированного текста (аннотация в OPF — HTML в сущностях).
fn stripTags(s: []u8) []const u8 {
    var n: usize = 0;
    var in_tag = false;
    for (s) |c| {
        if (c == '<') in_tag = true else if (c == '>' and in_tag) {
            in_tag = false;
            if (n > 0 and s[n - 1] != ' ') {
                s[n] = ' ';
                n += 1;
            }
        } else if (!in_tag) {
            s[n] = c;
            n += 1;
        }
    }
    return std.mem.trim(u8, s[0..n], " ");
}

pub fn looksLike(bytes: []const u8) bool {
    return bytes.len > 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, budget: *Budget) Error!Parsed {
    const zip = common.Zip.open(a, bytes) catch |err| return if (err == error.Damaged) error.NotEpub else err;

    // где лежит OPF
    var opf_path: []const u8 = "";
    if (zip.find("META-INF/container.xml")) |e| {
        const xml = try zip.read(a, e, budget);
        var m = Markup{ .s = xml };
        while (m.next()) |p| switch (p) {
            .tag => |tag| if (std.ascii.eqlIgnoreCase(common.tagName(tag), "rootfile")) {
                if (common.attr(tag, "full-path")) |v| {
                    opf_path = v;
                    break;
                }
            },
            .text => {},
        };
    }
    if (opf_path.len == 0) for (zip.entries) |e| if (std.ascii.endsWithIgnoreCase(e.name, ".opf")) {
        opf_path = e.name;
        break;
    };
    const opf_entry = zip.find(opf_path) orelse return error.NotEpub;
    const opf = try zip.read(a, opf_entry, budget);
    const base = if (std.mem.lastIndexOfScalar(u8, opf_entry.name, '/')) |s| opf_entry.name[0..s] else "";
    const utf8 = isUtf8(opf);

    var out = Parsed{};
    const Item = struct { id: []const u8, href: []const u8 };
    var items = std.ArrayList(Item).init(a);
    var spine = std.ArrayList([]const u8).init(a);
    var cover_id: []const u8 = "";
    var cover_href: []const u8 = "";
    var field: ?*[]const u8 = null;
    var field_text = Text{ .a = a, .budget = budget };
    var m = Markup{ .s = opf };
    while (m.next()) |p| switch (p) {
        .text => |s| if (field != null) try field_text.markup(s, utf8),
        .tag => |tag| {
            const name = common.tagName(tag);
            if (tag[0] == '/') {
                if (field) |f| {
                    const t = field_text.take();
                    if (f.len == 0) f.* = t;
                    field = null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "title")) {
                field = &out.title;
            } else if (std.ascii.eqlIgnoreCase(name, "creator")) {
                field = &out.author;
            } else if (std.ascii.eqlIgnoreCase(name, "description")) {
                field = &out.annotation;
            } else if (std.ascii.eqlIgnoreCase(name, "date")) {
                field = &out.year;
            } else if (std.ascii.eqlIgnoreCase(name, "meta")) {
                if (common.attr(tag, "name")) |n| if (std.mem.eql(u8, n, "calibre:series")) if (common.attr(tag, "content")) |v| {
                    var t = Text{ .a = a, .budget = budget };
                    try t.markup(v, utf8);
                    out.series = t.take();
                };
                if (common.attr(tag, "name")) |n| if (std.mem.eql(u8, n, "cover")) if (common.attr(tag, "content")) |v| {
                    cover_id = v;
                };
            } else if (std.ascii.eqlIgnoreCase(name, "item")) {
                if (items.items.len >= max_documents * 4) return error.TooBig;
                const id = common.attr(tag, "id") orelse continue;
                const href = common.attr(tag, "href") orelse continue;
                try items.append(.{ .id = id, .href = href });
                if (common.attr(tag, "properties")) |pr| if (std.mem.indexOf(u8, pr, "cover-image") != null) {
                    cover_href = href;
                };
            } else if (std.ascii.eqlIgnoreCase(name, "itemref")) {
                if (spine.items.len >= max_documents) return error.TooBig;
                try spine.append(common.attr(tag, "idref") orelse continue);
            }
        },
    };
    if (out.year.len > 4) out.year = out.year[0..4];
    for (out.year) |c| if (c < '0' or c > '9') {
        out.year = "";
        break;
    };
    if (out.annotation.len > 0) out.annotation = stripTags(try a.dupe(u8, out.annotation));
    if (out.annotation.len > 2000) out.annotation = out.annotation[0..2000];
    if (out.title.len > 300) out.title = out.title[0..300];
    if (out.author.len > 200) out.author = out.author[0..200];

    // шифрование содержимого — DRM: текста там нет
    const protected = zip.find("META-INF/encryption.xml") != null and zip.find("META-INF/rights.xml") != null;

    var book = Book{ .a = a, .budget = budget, .body = Text{ .a = a, .budget = budget }, .zip = &zip };
    for (spine.items) |idref| {
        const href = for (items.items) |it| {
            if (std.mem.eql(u8, it.id, idref)) break it.href;
        } else continue;
        // ссылка в OPF — тоже разметка: «&amp;» в имени файла
        var ht = Text{ .a = a, .budget = budget };
        try ht.markup(href, false);
        const path = try resolve(a, base, ht.take());
        const entry = zip.find(path) orelse continue;
        const doc = zip.read(a, entry, budget) catch |err| switch (err) {
            error.Damaged => continue, // один битый документ не губит книгу
            else => |e| return e,
        };
        try book.document(doc, if (std.mem.lastIndexOfScalar(u8, path, '/')) |sl| path[0..sl] else "");
    }
    try book.flush();
    if (book.chapters.items.len == 0) return if (protected) error.Protected else error.NotEpub;
    out.chapters = book.chapters.items;
    // обложка: properties="cover-image" (EPUB 3) или meta cover (EPUB 2)
    if (cover_href.len == 0 and cover_id.len > 0) for (items.items) |it| if (std.mem.eql(u8, it.id, cover_id)) {
        cover_href = it.href;
        break;
    };
    if (cover_href.len > 0) {
        var ht = Text{ .a = a, .budget = budget };
        try ht.markup(cover_href, false);
        out.cover = try book.image(try resolve(a, base, ht.take()), "");
    }
    out.images = book.images.items;
    return out;
}

test "epub: описание, порядок чтения, главы, сущности" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exp = @import("../export.zig");
    var packed_file = std.ArrayList(u8).init(a);
    var z = exp.Zip.init(&packed_file);
    try z.add("mimetype", "application/epub+zip", true);
    try z.add("META-INF/container.xml", "<?xml version=\"1.0\"?><container><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>", false);
    try z.add("OPS/book.opf",
        \\<?xml version="1.0" encoding="utf-8"?><package xmlns:dc="http://purl.org/dc/elements/1.1/">
        \\<metadata><dc:title>Степь &amp; море</dc:title><dc:creator opf:role="aut">Антон Чехов</dc:creator>
        \\<dc:description>&lt;p&gt;Первая.&lt;/p&gt;&lt;p&gt;Вторая.&lt;/p&gt;</dc:description><dc:date>1888-03-01</dc:date>
        \\<meta name="calibre:series" content="Повести"/><meta name="cover" content="cov"/></metadata>
        \\<manifest><item id="c2" href="text/two%20b.xhtml" media-type="application/xhtml+xml"/>
        \\<item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/><item id="css" href="s.css" media-type="text/css"/>
        \\<item id="gone" href="text/none.xhtml" media-type="application/xhtml+xml"/><item id="cov" href="img/c.jpg" media-type="image/jpeg"/></manifest>
        \\<spine><itemref idref="c1"/><itemref idref="gone"/><itemref idref="c2"/></spine></package>
    , false);
    try z.add("OPS/text/one.xhtml",
        \\<html><head><title>мусор</title><style>p { color: red }</style></head><body>
        \\<p>Вступление без&nbsp;заголовка.</p>
        \\<h1>Часть <i>первая</i></h1><h2>I</h2>
        \\<p>Из города выехала бричка&hellip;</p><p>Раз строка<br/>Два строка</p>
        \\<!-- <p>закомментировано</p> --><script>var x = "<p>нет</p>";</script>
        \\</body></html>
    , false);
    try z.add("OPS/text/two b.xhtml", "<html><body><div><h2>Глава 2</h2><div>Текст &lt;второй&gt; главы &#8212; всё.</div><p><img src=\"../img/a.png\" alt=\"Карта\"/></p><img src=\"../img/нет.png\"/></div></body></html>", false);
    try z.add("OPS/img/a.png", "\x89PNG картинка", false);
    try z.add("OPS/img/c.jpg", "\xff\xd8\xff обложка", false);
    try z.finish();
    const file = packed_file.items;

    var budget = Budget{ .left = 1 << 20 };
    try std.testing.expect(looksLike(file));
    const b = try parse(a, file, &budget);
    try std.testing.expectEqualStrings(cp.text("Степь & море"), b.title);
    try std.testing.expectEqualStrings(cp.text("Антон Чехов"), b.author);
    try std.testing.expectEqualStrings(cp.text("Первая. Вторая."), b.annotation);
    try std.testing.expectEqualStrings("1888", b.year);
    try std.testing.expectEqualStrings(cp.text("Повести"), b.series);
    try std.testing.expectEqual(@as(usize, 3), b.chapters.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(cp.text("Глава {d}"), .{1}), b.chapters[0].title);
    try std.testing.expectEqualStrings(cp.text("Вступление без заголовка."), b.chapters[0].text);
    try std.testing.expectEqualStrings(cp.text("Часть первая. I"), b.chapters[1].title);
    try std.testing.expectEqualStrings(cp.text("Из города выехала бричка…\n\nРаз строка\nДва строка"), b.chapters[1].text);
    try std.testing.expectEqualStrings(cp.text("Глава 2"), b.chapters[2].title);
    try std.testing.expectEqualStrings(cp.text("Текст <второй> главы — всё.\n\n\x010"), b.chapters[2].text);
    try std.testing.expectEqual(@as(usize, 2), b.images.len);
    try std.testing.expectEqualStrings("\x89PNG картинка", b.images[0].bytes);
    try std.testing.expectEqualStrings(cp.text("Карта"), b.images[0].caption);
    try std.testing.expectEqual(@as(?u32, 1), b.cover);
    try std.testing.expectEqualStrings("\xff\xd8\xff обложка", b.images[1].bytes);

    // предел распаковки и не-архив
    var tiny = Budget{ .left = 300 };
    try std.testing.expectError(error.TooBig, parse(a, file, &tiny));
    try std.testing.expectError(error.NotEpub, parse(a, "PK\x03\x04 это не архив", &budget));

    // испорченный файл не роняет разбор
    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    const copy = try a.dupe(u8, file);
    for (0..4000) |_| {
        @memcpy(copy, file);
        for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
        var bb = Budget{ .left = 1 << 20 };
        _ = parse(a, copy[0..rnd.intRangeAtMost(usize, 0, copy.len)], &bb) catch {};
    }
}
