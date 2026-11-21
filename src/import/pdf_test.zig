//! Тесты разбора PDF: файлы собираются здесь же, по объектам.

const std = @import("std");
const cp = @import("../cp1251.zig");
const pdf = @import("pdf.zig");
const Budget = @import("common.zig").Budget;

const testing = std.testing;

/// Собирает PDF из тел объектов (номера — с единицы, по порядку).
const Maker = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8),
    n: u32 = 0,

    fn init(a: std.mem.Allocator) Maker {
        var m = Maker{ .a = a, .out = std.ArrayList(u8).init(a) };
        m.out.appendSlice("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n") catch {};
        return m;
    }

    fn obj(m: *Maker, body: []const u8) !void {
        m.n += 1;
        try m.out.writer().print("{d} 0 obj\n{s}\nendobj\n", .{ m.n, body });
    }

    /// Поток; `pack` — сжать (FlateDecode).
    fn stream(m: *Maker, dict: []const u8, data: []const u8, pack: bool) !void {
        m.n += 1;
        var body = data;
        var packed_buf = std.ArrayList(u8).init(m.a);
        if (pack) {
            var in = std.io.fixedBufferStream(data);
            try std.compress.zlib.compress(in.reader(), packed_buf.writer(), .{});
            body = packed_buf.items;
        }
        try m.out.writer().print("{d} 0 obj\n<< {s}{s} /Length {d} >>\nstream\n", .{ m.n, dict, if (pack) " /Filter /FlateDecode" else "", body.len });
        try m.out.appendSlice(body);
        try m.out.appendSlice("\nendstream\nendobj\n");
    }

    fn finish(m: *Maker, trailer: []const u8) ![]const u8 {
        try m.out.writer().print("trailer\n<< /Size {d} {s} >>\nstartxref\n0\n%%EOF\n", .{ m.n + 1, trailer });
        return m.out.items;
    }
};

fn parseOk(a: std.mem.Allocator, file: []const u8) !@import("../fb2.zig").Parsed {
    var budget = Budget{ .left = 64 << 20 };
    return pdf.parse(a, file, &budget);
}

test "pdf: простой шрифт, строки в абзацы, перенос, номер страницы" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Maker.init(a);
    try m.obj("<< /Type /Catalog /Pages 2 0 R >>");
    try m.obj("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 /Resources << /Font << /F1 7 0 R >> >> >>");
    try m.obj("<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>");
    try m.stream("",
        \\BT /F1 12 Tf 72 720 Td
        \\(The first paragraph begins here and this line is long eno-) Tj
        \\0 -14 Td (ugh to wrap around. The second sentence of it ends here.) Tj
        \\1 0 0 1 92 692 Tm (A new paragraph starts with an indent and continues to the) Tj
        \\1 0 0 1 72 678 Tm [(right mar) -20 (gin of the pa) 15 (ge) -600 (and) -300 (on.)] TJ
        \\1 0 0 1 300 40 Tm (1) Tj ET
    , false);
    try m.obj("<< /Type /Page /Parent 2 0 R /Contents [6 0 R] >>");
    try m.stream("", "q 1 0 0 1 72 700 cm BT /F1 12 Tf 0 0 Td (The text of the second page follows \\(with brackets\\) and \\101 octal.) Tj T* ET Q", false);
    try m.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    try m.obj("<< /Title (Microsoft Word - Proba pera) /Author <FEFF0410043D0442043E043D0020042704350445043E0432> >>");
    const file = try m.finish("/Root 1 0 R /Info 8 0 R");

    const b = try parseOk(a, file);
    try testing.expectEqualStrings("Proba pera", b.title);
    try testing.expectEqualStrings(cp.text("Антон Чехов"), b.author);
    try testing.expectEqual(@as(usize, 1), b.chapters.len);
    try testing.expectEqualStrings(
        "The first paragraph begins here and this line is long enough to wrap around. The second sentence of it ends here.\n\n" ++
            "A new paragraph starts with an indent and continues to the right margin of the page and on.\n\n" ++
            "The text of the second page follows (with brackets) and A octal.",
        b.chapters[0].text,
    );
}

/// Русский текст → коды шрифта теста: пробел 0001, точка 0002, А–я 0010–004F.
fn hexRu(a: std.mem.Allocator, utf8: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < utf8.len) {
        const u, const l = cp.utf8Next(utf8, i);
        i += l;
        const code: u32 = switch (u) {
            ' ' => 1,
            '.' => 2,
            0x410...0x44F => 0x10 + (u - 0x410),
            else => 3, // знака нет в таблице
        };
        try out.writer().print("{X:0>4}", .{code});
    }
    return out.items;
}

const cmap =
    \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
    \\/CMapName /Adobe-Identity-UCS def /CMapType 2 def
    \\1 begincodespacerange <0000> <FFFF> endcodespacerange
    \\2 beginbfchar
    \\<0001> <0020>
    \\<0002> <002E>
    \\endbfchar
    \\2 beginbfrange
    \\<0010> <002F> <0410>
    \\<0030> <004F> [<0430> <0431> <0432> <0433> <0434> <0435> <0436> <0437> <0438> <0439> <043A> <043B> <043C> <043D> <043E> <043F> <0440> <0441> <0442> <0443> <0444> <0445> <0446> <0447> <0448> <0449> <044A> <044B> <044C> <044D> <044E> <044F>]
    \\endbfrange
    \\endcmap CMapName currentdict /CMap defineresource pop end end
;

fn russianBook(a: std.mem.Allocator, with_table: bool) ![]const u8 {
    var m = Maker.init(a);
    try m.obj("<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>");
    try m.obj("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>");
    const res = "/Resources << /Font << /F1 7 0 R >> >>";
    try m.obj(try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R {s} /Contents 5 0 R >>", .{res}));
    try m.obj(try std.fmt.allocPrint(a, "<< /Type /Page /Parent 2 0 R {s} /Contents 6 0 R >>", .{res}));
    var p1 = std.ArrayList(u8).init(a);
    try p1.writer().print("BT /F1 10 Tf 1 0 0 1 60 760 Tm <{s}> Tj\n", .{try hexRu(a, "Из города выехала бричка и с громом покатила по почтовому")});
    try p1.writer().print("1 0 0 1 60 748 Tm [<{s}> -250 <{s}>] TJ\n", .{ try hexRu(a, "тракту."), try hexRu(a, "В бричке сидели двое обывателей города.") });
    try p1.writer().print("1 0 0 1 75 736 Tm <{s}> Tj ET\n", .{try hexRu(a, "Кроме них в бричке находился еще один пассажир.")});
    try m.stream("", p1.items, true);
    var p2 = std.ArrayList(u8).init(a);
    try p2.writer().print("BT /F1 10 Tf 1 0 0 1 60 760 Tm <{s}> Tj\n", .{try hexRu(a, "Вторая глава началась на новой странице и тоже довольно")});
    try p2.writer().print("1 0 0 1 60 748 Tm <{s}> Tj ET\n", .{try hexRu(a, "длинная. Чтобы текста хватило на проверку текстового слоя.")});
    try m.stream("", p2.items, true);
    try m.obj(if (with_table) "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Serif /Encoding /Identity-H /DescendantFonts [8 0 R] /ToUnicode 9 0 R >>" else "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Serif /Encoding /Identity-H /DescendantFonts [8 0 R] >>");
    try m.obj("<< /Type /Font /Subtype /CIDFontType2 /DW 500 /W [1 [250 250] 16 79 520] >>");
    try m.stream("", cmap, true);
    try m.obj("<< /Type /Outlines /First 11 0 R /Last 12 0 R /Count 2 >>");
    try m.obj("<< /Title <FEFF0413043B043004320430002004310435043B0430044F> /Parent 10 0 R /Next 12 0 R /Dest [3 0 R /Fit] >>");
    try m.obj("<< /Title (Second) /Parent 10 0 R /Prev 11 0 R /A << /S /GoTo /D [4 0 R /XYZ 0 0 0] >> >>");
    return m.finish("/Root 1 0 R");
}

test "pdf: составной шрифт с ToUnicode, сжатые потоки, главы из оглавления" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try parseOk(a, try russianBook(a, true));
    try testing.expectEqual(@as(usize, 2), b.chapters.len);
    try testing.expectEqualStrings(cp.text("Глава белая"), b.chapters[0].title);
    try testing.expectEqualStrings(cp.text("Из города выехала бричка и с громом покатила по почтовому тракту. В бричке сидели двое обывателей города.\n\nКроме них в бричке находился еще один пассажир."), b.chapters[0].text);
    try testing.expectEqualStrings("Second", b.chapters[1].title);
    try testing.expectEqualStrings(cp.text("Вторая глава началась на новой странице и тоже довольно длинная. Чтобы текста хватило на проверку текстового слоя."), b.chapters[1].text);
}

test "pdf: скан, пароль, шрифт без таблицы, не PDF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // буквы не переводятся: составной шрифт без ToUnicode
    try testing.expectError(error.Garbled, parseOk(a, try russianBook(a, false)));
    // страница-картинка
    var m = Maker.init(a);
    try m.obj("<< /Type /Catalog /Pages 2 0 R >>");
    try m.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    try m.obj("<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>");
    try m.stream("", "q 595 0 0 842 0 0 cm /Im0 Do Q BI /W 2 /H 2 /BPC 8 /CS /G ID \x00\xff(Tj\x00 EI BT ET", false);
    try m.stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", "\x00\xff\xff\x00", false);
    try testing.expectError(error.NoText, parseOk(a, try m.finish("/Root 1 0 R")));
    // пароль
    var e = Maker.init(a);
    try e.obj("<< /Type /Catalog /Pages 2 0 R >>");
    try e.obj("<< /Type /Pages /Kids [] /Count 0 >>");
    try testing.expectError(error.Encrypted, parseOk(a, try e.finish("/Root 1 0 R /Encrypt << /Filter /Standard /V 1 >>")));
    try testing.expectError(error.NotPdf, parseOk(a, "<html>"));
    try testing.expectError(error.NotPdf, parseOk(a, "%PDF-1.7\nпусто"));
    // предел распаковки
    var tiny = Budget{ .left = 2000 };
    try testing.expectError(error.TooBig, pdf.parse(a, try russianBook(a, true), &tiny));
}

test "pdf: испорченный файл не роняет разбор" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var keep = std.heap.ArenaAllocator.init(testing.allocator);
    defer keep.deinit();
    const good = try russianBook(keep.allocator(), true);
    const copy = try keep.allocator().dupe(u8, good);
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    const alphabet = "<>[]()/%0123456789 RobjendstreamTjBTfdcmqQ\n\r.-+#\\\x00\xff";
    var ok: usize = 0;
    for (0..6000) |i| {
        @memcpy(copy, good);
        for (0..rnd.intRangeAtMost(usize, 1, 8)) |_| {
            copy[rnd.uintLessThan(usize, copy.len)] = if (i % 2 == 0) rnd.int(u8) else alphabet[rnd.uintLessThan(usize, alphabet.len)];
        }
        const len = if (i % 5 == 0) rnd.intRangeAtMost(usize, 0, copy.len) else copy.len;
        var budget = Budget{ .left = 8 << 20 };
        if (pdf.parse(a, copy[0..len], &budget)) |_| {
            ok += 1;
        } else |_| {}
        _ = arena.reset(.retain_capacity);
    }
    try testing.expect(ok > 100); // порча не всегда губит файл: разбор проверен и на уцелевших
}
