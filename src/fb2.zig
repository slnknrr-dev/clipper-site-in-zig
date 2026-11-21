//! Исходные книги из `books/`: FB2 (XML) и текст. Разбор терпим к мусору и
//! не доверяет входу: ни рекурсии, ни выделений больше размера файла, все
//! обращения к байтам проверены. Результат — строки в windows-1251.
//!
//! Картинки (<image l:href="#id">, данные — <binary id>) не разбираются здесь:
//! в тексте главы на месте картинки — абзац-метка «\x01N» (N — номер в
//! Parsed.images), а сами байты и подпись — в Parsed.images (BACKLOG_RU.md §17).

const std = @import("std");
const cp = @import("cp1251.zig");

pub const Chapter = @import("snapshot.zig").InChapter;

/// Картинка книги до обработки: байты файла (PNG, JPEG или что угодно — решит
/// обработка) и подпись в windows-1251.
pub const SrcImage = struct { bytes: []const u8, caption: []const u8 = "" };

/// Абзац-метка картинки номер `k` в тексте главы.
pub fn imageMark(buf: *[16]u8, k: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\x01{d}", .{k}) catch unreachable;
}

/// Номер картинки, если абзац — её метка.
pub fn imageOf(para: []const u8) ?u32 {
    if (para.len < 2 or para[0] != 1) return null;
    return std.fmt.parseInt(u32, para[1..], 10) catch null;
}

pub const max_images = 2000;

pub const Parsed = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    /// для книг, сохранённых самим сайтом: номера вместо имён
    author_id: i32 = 0,
    uploader: i32 = 0,
    drafts: []const i32 = &.{},
    series: []const u8 = "",
    year: []const u8 = "",
    annotation: []const u8 = "",
    chapters: []const Chapter = &.{},
    /// картинки текста по номерам меток; обложка — номер в том же списке
    images: []const SrcImage = &.{},
    cover: ?u32 = null,
};

const max_chapters = 20000;

const Tag = enum { other, description, title_info, book_title, author, first_name, middle_name, last_name, annotation, date, sequence, body, section, title, p, v, stanza, subtitle, text_author, empty_line, binary, epigraph, poem, cite, image, coverpage };

fn tagOf(name: []const u8) Tag {
    const map = .{
        .{ "description", .description }, .{ "title-info", .title_info }, .{ "book-title", .book_title }, .{ "author", .author },
        .{ "first-name", .first_name },   .{ "middle-name", .middle_name }, .{ "last-name", .last_name },   .{ "annotation", .annotation },
        .{ "date", .date },               .{ "sequence", .sequence },     .{ "body", .body },             .{ "section", .section },
        .{ "title", .title },             .{ "p", .p },                   .{ "v", .v },                   .{ "stanza", .stanza },
        .{ "subtitle", .subtitle },       .{ "text-author", .text_author }, .{ "empty-line", .empty_line }, .{ "binary", .binary },
        .{ "epigraph", .epigraph },       .{ "poem", .poem },             .{ "cite", .cite },
        .{ "image", .image },             .{ "coverpage", .coverpage },
    };
    inline for (map) |m| if (std.ascii.eqlIgnoreCase(name, m[0])) return m[1];
    return .other;
}

const Text = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},
    utf8: bool,
    space: bool = false,

    fn put(t: *Text, c: u8) !void {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0xA0) {
            t.space = t.buf.items.len > 0;
            return;
        }
        if (c < 0x20) return;
        if (t.space) try t.buf.append(t.a, ' ');
        t.space = false;
        try t.buf.append(t.a, c);
    }

    fn putUnicode(t: *Text, u: u21) !void {
        try t.put(cp.fromUnicode(u) orelse switch (u) {
            0x2012, 0x2015, 0x2212 => 0x96,
            0x00C0...0x00FF, 0x0100...0x017F => '?',
            else => '?',
        });
    }

    /// Текст между тегами: сущности и перекодировка.
    fn add(t: *Text, raw: []const u8) !void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '&') {
                const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse raw.len;
                if (end < raw.len and end - i <= 10) {
                    const name = raw[i + 1 .. end];
                    const u: ?u21 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else if (std.mem.eql(u8, name, "nbsp")) ' ' else if (name.len > 1 and name[0] == '#')
                        (if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) catch null else std.fmt.parseInt(u21, name[1..], 10) catch null)
                    else
                        null;
                    if (u) |x| {
                        try t.putUnicode(x);
                        i = end + 1;
                        continue;
                    }
                }
                try t.put('&');
                i += 1;
            } else if (c < 0x80 or !t.utf8) {
                try t.put(c);
                i += 1;
            } else {
                const u, const l = cp.utf8Next(raw, i);
                try t.putUnicode(u);
                i += l;
            }
        }
    }

    fn take(t: *Text) []const u8 {
        const s = t.buf.items;
        t.buf = .{};
        t.space = false;
        return s;
    }
};

fn attrValue(tag: []const u8, comptime name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, name ++ "=")) |i| {
        from = i + 1;
        if (i > 0 and tag[i - 1] != ' ' and tag[i - 1] != '\t' and tag[i - 1] != '\n' and tag[i - 1] != ':') continue;
        const q = i + name.len + 1;
        if (q >= tag.len or (tag[q] != '"' and tag[q] != '\'')) continue;
        const end = std.mem.indexOfScalarPos(u8, tag, q + 1, tag[q]) orelse return null;
        return tag[q + 1 .. end];
    }
    return null;
}

const ChapterBuf = struct { title: std.ArrayListUnmanaged(u8) = .{}, text: std.ArrayListUnmanaged(u8) = .{} };

pub fn parse(a: std.mem.Allocator, bytes_in: []const u8) !Parsed {
    var bytes = bytes_in;
    var utf8 = true;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) {
        bytes = bytes[3..];
    } else if (std.mem.startsWith(u8, bytes, "\xFF\xFE") or std.mem.startsWith(u8, bytes, "\xFE\xFF")) {
        return error.Utf16NotSupported;
    }
    if (std.mem.startsWith(u8, bytes, "<?xml")) {
        const decl = bytes[0..@min(bytes.len, std.mem.indexOf(u8, bytes, "?>") orelse 200)];
        if (attrValue(decl, "encoding")) |enc| {
            if (std.ascii.indexOfIgnoreCase(enc, "1251") != null) utf8 = false else if (!std.ascii.eqlIgnoreCase(enc, "utf-8") and !std.ascii.eqlIgnoreCase(enc, "utf8")) return error.UnknownEncoding;
        }
    }
    if (std.mem.indexOf(u8, bytes[0..@min(bytes.len, 4096)], "<FictionBook") == null) return error.NotFb2;

    var out = Parsed{};
    var stack: [64]Tag = undefined;
    var depth: usize = 0;
    var text = Text{ .a = a, .utf8 = utf8 };
    var chapters = std.ArrayList(ChapterBuf).init(a);
    var annotation: std.ArrayListUnmanaged(u8) = .{};
    var name_parts: [3][]const u8 = .{ "", "", "" };
    var have_author = false;
    var bodies: usize = 0;
    var skip_body = false;
    var loose = ChapterBuf{}; // текст тела вне разделов
    var prev_verse = false;
    var stanza_break = false;
    // картинки: ссылки по порядку (номер метки) и данные <binary> по id
    const Ref = struct { id: []const u8, caption: []const u8 };
    var refs = std.ArrayList(Ref).init(a);
    var cover_ref: ?[]const u8 = null;
    var binaries = std.StringHashMap([]const u8).init(a);

    const has = struct {
        fn f(st: []const Tag, t: Tag) bool {
            return std.mem.indexOfScalar(Tag, st, t) != null;
        }
    }.f;

    var i: usize = 0;
    while (i < bytes.len) {
        const lt = std.mem.indexOfScalarPos(u8, bytes, i, '<') orelse bytes.len;
        if (lt > i) {
            const st = stack[0..depth];
            const wanted = depth > 0 and !skip_body and switch (st[depth - 1]) {
                .binary, .description, .title_info, .body, .section, .other => (st[depth - 1] == .other and depth > 1 and (has(st, .p) or has(st, .v) or has(st, .subtitle) or has(st, .text_author) or has(st, .book_title))),
                else => true,
            };
            if (wanted) try text.add(bytes[i..lt]);
        }
        if (lt == bytes.len) break;
        // тег
        if (std.mem.startsWith(u8, bytes[lt..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, bytes, lt, "-->")) |e| e + 3 else bytes.len;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[lt..], "<![CDATA[")) {
            const e = std.mem.indexOfPos(u8, bytes, lt, "]]>") orelse bytes.len;
            if (depth > 0 and !skip_body and lt + 9 <= e) for (bytes[lt + 9 .. e]) |c| try text.put(if (c < 0x80 or !utf8) c else '?');
            i = @min(bytes.len, e + 3);
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, bytes, lt, '>') orelse break;
        const inner = bytes[lt + 1 .. gt];
        i = gt + 1;
        if (inner.len == 0 or inner[0] == '?' or inner[0] == '!') continue;
        const closing = inner[0] == '/';
        const self_closing = inner[inner.len - 1] == '/';
        var name = if (closing) inner[1..] else inner;
        if (std.mem.indexOfAny(u8, name, " \t\r\n/")) |e| name = name[0..e];
        if (std.mem.indexOfScalar(u8, name, ':')) |c| name = name[c + 1 ..];
        const tag = tagOf(name);

        if (!closing) {
            const st = stack[0..depth];
            switch (tag) {
                .binary => {
                    // данные картинки (base64) — до закрывающего тега, разбираются потом
                    if (!self_closing) {
                        const end = std.mem.indexOfPos(u8, bytes, i, "</binary>") orelse bytes.len;
                        if (attrValue(inner, "id")) |id| try binaries.put(id, bytes[i..end]);
                        i = @min(bytes.len, end + 9);
                    }
                    continue;
                },
                .image => {
                    const href = attrValue(inner, "href") orelse "";
                    const id = if (std.mem.startsWith(u8, href, "#")) href[1..] else "";
                    if (id.len > 0) {
                        if (has(st, .coverpage)) {
                            if (cover_ref == null) cover_ref = id;
                        } else if (has(st, .body) and !skip_body and refs.items.len < max_images and !has(st, .title)) {
                            var cap: []const u8 = "";
                            if (attrValue(inner, "title")) |t| {
                                var t2 = Text{ .a = a, .utf8 = utf8 };
                                try t2.add(t);
                                cap = t2.take();
                            }
                            // метка — отдельным абзацем текущей главы
                            const ch = if (chapters.items.len > 0) &chapters.items[chapters.items.len - 1] else &loose;
                            var mb: [16]u8 = undefined;
                            if (ch.text.items.len > 0) try ch.text.appendSlice(a, "\n\n");
                            try ch.text.appendSlice(a, imageMark(&mb, refs.items.len));
                            try refs.append(.{ .id = id, .caption = cap });
                            prev_verse = false;
                        }
                    }
                },
                .body => {
                    bodies += 1;
                    skip_body = bodies > 1; // примечания и прочие тела не читаем
                },
                .section => if (!skip_body and has(st, .body)) {
                    if (chapters.items.len >= max_chapters) return error.TooManyChapters;
                    try chapters.append(.{});
                },
                .sequence => if (has(st, .title_info) and out.series.len == 0) {
                    if (attrValue(inner, "name")) |n| {
                        var t2 = Text{ .a = a, .utf8 = utf8 };
                        try t2.add(n);
                        out.series = t2.take();
                    }
                },
                .date => if (has(st, .title_info) and out.year.len == 0) {
                    if (attrValue(inner, "value")) |v| {
                        if (v.len >= 4) out.year = try a.dupe(u8, v[0..4]);
                    }
                },
                .empty_line => {},
                else => {},
            }
            if (self_closing) continue;
            if (depth == stack.len) return error.TooDeep;
            stack[depth] = tag;
            depth += 1;
            switch (tag) {
                .p, .v, .subtitle, .text_author, .book_title, .first_name, .middle_name, .last_name, .date => _ = text.take(),
                else => {},
            }
            continue;
        }

        // закрывающий тег: снять со стека до него (терпим незакрытые)
        var d = depth;
        while (d > 0 and stack[d - 1] != tag) d -= 1;
        if (d == 0) continue; // лишний закрывающий
        depth = d - 1;
        const st = stack[0..depth];
        switch (tag) {
            .book_title => if (has(st, .title_info) and out.title.len == 0) {
                out.title = text.take();
            },
            .first_name, .middle_name, .last_name => if (has(st, .title_info) and has(st, .author) and !have_author) {
                name_parts[switch (tag) {
                    .first_name => 0,
                    .middle_name => 1,
                    else => 2,
                }] = text.take();
            },
            .author => if (has(st, .title_info) and !have_author) {
                // имя и фамилия, как в макете: «Александр Пушкин»
                var nb = std.ArrayList(u8).init(a);
                for ([_][]const u8{ name_parts[0], name_parts[2] }) |part| {
                    if (part.len == 0) continue;
                    if (nb.items.len > 0) try nb.append(' ');
                    try nb.appendSlice(part);
                }
                out.author = nb.items;
                have_author = out.author.len > 0;
            },
            .date => if (has(st, .title_info) and out.year.len == 0) {
                const t = text.take();
                var k: usize = 0;
                while (k + 4 <= t.len) : (k += 1) {
                    if (std.ascii.isDigit(t[k]) and std.ascii.isDigit(t[k + 1]) and std.ascii.isDigit(t[k + 2]) and std.ascii.isDigit(t[k + 3])) {
                        out.year = t[k .. k + 4];
                        break;
                    }
                }
            },
            .p, .v, .subtitle, .text_author => {
                const t = text.take();
                if (t.len == 0) continue;
                if (has(st, .annotation) and has(st, .title_info)) {
                    if (annotation.items.len > 0) try annotation.append(a, '\n');
                    try annotation.appendSlice(a, t);
                } else if (has(st, .body) and !skip_body) {
                    const ch = if (chapters.items.len > 0) &chapters.items[chapters.items.len - 1] else &loose;
                    if (has(st, .title)) {
                        if (!has(st, .section)) continue; // заголовок тела — это название книги
                        if (ch.text.items.len == 0) {
                            if (ch.title.items.len > 0) try ch.title.append(a, ' ');
                            try ch.title.appendSlice(a, t);
                            continue;
                        }
                    }
                    // строки одной строфы идут подряд, всё остальное — отдельными абзацами
                    const joined = tag == .v and prev_verse and !stanza_break;
                    if (ch.text.items.len > 0) try ch.text.appendSlice(a, if (joined) "\n" else "\n\n");
                    try ch.text.appendSlice(a, t);
                    prev_verse = tag == .v;
                    stanza_break = false;
                }
            },
            .stanza => stanza_break = true,
            else => {},
        }
    }

    out.annotation = annotation.items;
    var list = std.ArrayList(Chapter).init(a);
    var carry: []const u8 = "";
    const all = try a.alloc(ChapterBuf, chapters.items.len + 1);
    all[0] = loose;
    @memcpy(all[1..], chapters.items);
    for (all) |*ch| {
        const body = std.mem.trim(u8, ch.text.items, "\n ");
        var title: []const u8 = ch.title.items;
        if (body.len == 0) {
            // раздел-оглавление: его название уходит в начало следующего
            if (title.len > 0) carry = if (carry.len > 0) try std.fmt.allocPrint(a, "{s}. {s}", .{ carry, title }) else title;
            continue;
        }
        if (carry.len > 0) {
            title = if (title.len > 0) try std.fmt.allocPrint(a, "{s}. {s}", .{ carry, title }) else carry;
            carry = "";
        }
        if (title.len == 0) title = try std.fmt.allocPrint(a, cp.text("Глава {d}"), .{list.items.len + 1});
        if (title.len > 200) title = title[0..200];
        try list.append(.{ .title = title, .text = body });
    }
    out.chapters = list.items;
    if (out.title.len > 300) out.title = out.title[0..300];

    // картинки: base64 из <binary>; чего нет или что не раскодировалось — пустые байты
    const images = try a.alloc(SrcImage, refs.items.len + @intFromBool(cover_ref != null));
    for (refs.items, 0..) |r, k| images[k] = .{ .bytes = try binary(a, binaries.get(r.id)), .caption = r.caption };
    if (cover_ref) |id| {
        // обложка — тот же номер, если она есть и в тексте
        out.cover = for (refs.items, 0..) |r, k| {
            if (std.mem.eql(u8, r.id, id)) break @intCast(k);
        } else blk: {
            images[refs.items.len] = .{ .bytes = try binary(a, binaries.get(id)) };
            break :blk @intCast(refs.items.len);
        };
    }
    out.images = images[0 .. refs.items.len + @intFromBool(cover_ref != null and out.cover.? == refs.items.len)];
    return out;
}

/// Данные <binary>: base64 с пробелами и переводами строк.
fn binary(a: std.mem.Allocator, b64: ?[]const u8) ![]const u8 {
    const src = b64 orelse return "";
    const dec = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const out = try a.alloc(u8, src.len / 4 * 3 + 3);
    const n = dec.decode(out, src) catch return "";
    return out[0..n];
}

/// Текстовая книга. Главы начинаются строкой «## Название»; без заголовков — одна
/// глава. Файлы, сохранённые сайтом, несут шапку `#clipper-book` с полями.
pub fn parseTxt(a: std.mem.Allocator, bytes_in: []const u8) !Parsed {
    var bytes = bytes_in;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes = bytes[3..];
    var text: []const u8 = if (cp.looksUtf8(bytes)) try cp.encodeAlloc(a, bytes) else bytes;
    var out = Parsed{};
    if (std.mem.startsWith(u8, text, "#clipper-book")) {
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next();
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r ");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const k = line[0..colon];
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.mem.eql(u8, k, "title")) out.title = v else if (std.mem.eql(u8, k, "author-name")) out.author = v else if (std.mem.eql(u8, k, "series")) out.series = v else if (std.mem.eql(u8, k, "year")) out.year = v else if (std.mem.eql(u8, k, "annotation")) out.annotation = v else if (std.mem.eql(u8, k, "author")) out.author_id = std.fmt.parseInt(i32, v, 10) catch 0 else if (std.mem.eql(u8, k, "uploader")) out.uploader = std.fmt.parseInt(i32, v, 10) catch 0 else if (std.mem.eql(u8, k, "drafts")) {
                var ids = std.ArrayList(i32).init(a);
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |x| try ids.append(std.fmt.parseInt(i32, std.mem.trim(u8, x, " "), 10) catch continue);
                out.drafts = ids.items;
            }
        }
        text = lines.rest();
    }
    out.chapters = try splitChapters(a, text);
    return out;
}

pub fn splitChapters(a: std.mem.Allocator, text: []const u8) ![]const Chapter {
    var list = std.ArrayList(Chapter).init(a);
    var cur_title: []const u8 = cp.text("Текст");
    var start: usize = 0;
    var pos: usize = 0;
    const Add = struct {
        fn f(l: *std.ArrayList(Chapter), title: []const u8, body_raw: []const u8) !void {
            const body = std.mem.trim(u8, body_raw, "\r\n ");
            if (body.len == 0) return;
            if (l.items.len >= max_chapters) return error.TooManyChapters;
            try l.append(.{ .title = title, .text = body });
        }
    };
    while (pos < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..eol];
        if (std.mem.startsWith(u8, line, "##")) {
            try Add.f(&list, cur_title, text[start..pos]);
            const t = std.mem.trim(u8, line[2..], " \r\t");
            cur_title = if (t.len > 0) t[0..@min(t.len, 200)] else try std.fmt.allocPrint(a, cp.text("Глава {d}"), .{list.items.len + 1});
            start = @min(text.len, eol + 1);
        }
        pos = eol + 1;
    }
    try Add.f(&list, cur_title, text[@min(start, text.len)..]);
    return list.items;
}

test "fb2: описание, разделы, стихи, сущности" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
        \\<description><title-info><genre>prose</genre><author><first-name>Антон</first-name><middle-name>П.</middle-name><last-name>Чехов</last-name></author>
        \\<book-title>Степь &amp; море</book-title><annotation><p>Первая.</p><p>Вторая.</p></annotation><date value="1888-01-01">1888</date>
        \\<sequence name="Повести" number="1"/></title-info><document-info><author><nickname>x</nickname></author></document-info></description>
        \\<body><title><p>Степь</p></title>
        \\<section><title><p>Часть первая</p></title>
        \\<section><title><p>I</p></title><p>Из   города <emphasis>выехала</emphasis> бричка.</p><p>Вторая&#160;строка &lt;тут&gt;.</p>
        \\<poem><stanza><v>Раз строка</v><v>Два строка</v></stanza><stanza><v>Три</v></stanza></poem><p>После.</p></section>
        \\<section><p>Без названия.</p></section></section></body>
        \\<body name="notes"><section><p>сноска</p></section></body>
        \\<binary id="c.jpg" content-type="image/jpeg">AAAA<<<<</binary></FictionBook>
    ;
    const b = try parse(a, src);
    try std.testing.expectEqualStrings(cp.text("Степь & море"), b.title);
    try std.testing.expectEqualStrings(cp.text("Антон Чехов"), b.author);
    try std.testing.expectEqualStrings("1888", b.year);
    try std.testing.expectEqualStrings(cp.text("Повести"), b.series);
    try std.testing.expectEqualStrings(cp.text("Первая.\nВторая."), b.annotation);
    try std.testing.expectEqual(@as(usize, 2), b.chapters.len);
    try std.testing.expectEqualStrings(cp.text("Часть первая. I"), b.chapters[0].title);
    try std.testing.expectEqualStrings(cp.text("Из города выехала бричка.\n\nВторая строка <тут>.\n\nРаз строка\nДва строка\n\nТри\n\nПосле."), b.chapters[0].text);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(cp.text("Глава {d}"), .{2}), b.chapters[1].title);
}

test "fb2: картинки — метки в тексте, данные из binary, обложка" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>К</book-title>
        \\<coverpage><image l:href="#cover.jpg"/></coverpage></title-info></description>
        \\<body><section><title><p>I</p></title><p>До.</p><image l:href="#a.png" title="Рисунок &amp; подпись"/><p>После.</p>
        \\<image l:href="#нет"/></section><section><image l:href="#a.png"/></section></body>
        \\<binary id="a.png" content-type="image/png">iVBO
        \\Rw0K</binary><binary id="cover.jpg" content-type="image/jpeg">/9j/4A==</binary></FictionBook>
    ;
    const b = try parse(a, src);
    try std.testing.expectEqual(@as(usize, 2), b.chapters.len);
    try std.testing.expectEqualStrings(cp.text("До.\n\n\x010\n\nПосле.\n\n\x011"), b.chapters[0].text);
    try std.testing.expectEqualStrings("\x012", b.chapters[1].text);
    try std.testing.expectEqual(@as(usize, 4), b.images.len);
    try std.testing.expectEqualStrings("\x89PNG\r\n", b.images[0].bytes);
    try std.testing.expectEqualStrings(cp.text("Рисунок & подпись"), b.images[0].caption);
    try std.testing.expectEqual(@as(usize, 0), b.images[1].bytes.len); // нет такого binary
    try std.testing.expectEqual(@as(?u32, 3), b.cover);
    try std.testing.expectEqualStrings("\xff\xd8\xff\xe0", b.images[3].bytes);
    try std.testing.expectEqual(@as(?u32, 0), imageOf("\x010"));
    try std.testing.expectEqual(@as(?u32, null), imageOf("текст"));
}

test "fb2: враждебный ввод не роняет разбор" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotFb2, parse(a, "<html></html>"));
    try std.testing.expectError(error.NotFb2, parse(a, ""));
    const deep = "<FictionBook><body>" ++ "<section>" ** 100 ++ "<p>x</p>";
    try std.testing.expectError(error.TooDeep, parse(a, deep));
    const cases = [_][]const u8{
        "<FictionBook><body><section><p>незакрыто",
        "<FictionBook><body></p></section></body></x></FictionBook>",
        "<FictionBook><description><title-info><book-title>&#xFFFFFFFF;&bogus;&#;&</book-title><sequence name=/></title-info></description><",
        "<FictionBook><body><section><p>a<![CDATA[b</p>",
        "<FictionBook><binary>zzz",
        "<FictionBook><!-- <body><section><p>x",
        "<FictionBook><body><section><title><p>t</p></title></section><section><v>\xff\xfe\xc3</v></section>",
    };
    for (cases) |c| _ = try parse(a, c);
    // случайный мусор и случайно испорченный настоящий файл
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    const alphabet = "<>/&;#\"='p vsectionbodytitle!-[]CDATA\n\xd0\x90x";
    var buf: [600]u8 = undefined;
    for (0..3000) |_| {
        const head = "<FictionBook>";
        @memcpy(buf[0..head.len], head);
        const n = rnd.intRangeAtMost(usize, head.len, buf.len);
        for (buf[head.len..n]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        _ = parse(a, buf[0..n]) catch {};
        _ = arena.reset(.retain_capacity);
    }
}

test "текстовая книга" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try parseTxt(a, "#clipper-book\ntitle: T\nauthor: -101\nuploader: 1001\ndrafts: 1, 3\n\nвступление\n## Первая\nтекст 1\n\n##\nтекст 2\n");
    try std.testing.expectEqualStrings("T", b.title);
    try std.testing.expectEqual(@as(i32, -101), b.author_id);
    try std.testing.expectEqual(@as(usize, 2), b.drafts.len);
    try std.testing.expectEqual(@as(usize, 3), b.chapters.len);
    try std.testing.expectEqualStrings(cp.text("Текст"), b.chapters[0].title);
    try std.testing.expectEqualStrings(cp.text("Первая"), b.chapters[1].title);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(cp.text("Глава {d}"), .{3}), b.chapters[2].title);
}
