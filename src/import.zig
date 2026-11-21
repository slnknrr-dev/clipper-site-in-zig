//! Загружаемые книги: формат файла, разбор и каноническая запись.
//!
//! Что бы ни прислали — FB2, EPUB, PDF, DjVu, текст, — книга приводится к одному
//! виду: описание (название, автор, серия, год, аннотация) и главы из абзацев
//! в windows-1251. В этом виде она лежит в снимке каталога, из него же
//! собираются скачивания txt, fb2 и epub. EPUB, PDF и DjVu при выкладывании
//! записываются в `books/` уже разобранными — каноническим текстовым файлом
//! (`canonical`), чтобы пересборка снимка не разбирала их заново.
//!
//! Картинки берутся только из FB2 и EPUB. PDF и DjVu — экспериментальные:
//! разбор есть только в сборке с -Dpdf / -Ddjvu (по умолчанию да), загрузку
//! включают флаги запуска -pdf / -djvu; принимаются только с текстовым слоем
//! (распознавания нет) и хранятся каноническим текстом.

const std = @import("std");
const cp = @import("cp1251.zig");
const fb2 = @import("fb2.zig");
const common = @import("import/common.zig");
const epub = @import("import/epub.zig");
const config = @import("config");
/// Разборщики PDF и DjVu есть только в сборке с -Dpdf / -Ddjvu.
pub const has_pdf = config.pdf;
pub const has_djvu = config.djvu;
const pdf = if (has_pdf) @import("import/pdf.zig") else struct {};
const djvu = if (has_djvu) @import("import/djvu.zig") else struct {};

fn looksPdf(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes[0..@min(bytes.len, 1024)], "%PDF-") != null;
}
fn looksDjvu(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "AT&TFORM");
}

pub const Parsed = fb2.Parsed;
pub const Budget = common.Budget;

pub const Kind = enum { fb2, txt, epub, pdf, djvu };

/// Сколько разборщик вправе распаковать и выделить на одну книгу.
pub const budget_bytes = 384 << 20;

fn hasExt(name: []const u8, comptime ext: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ext);
}

/// Формат по содержимому; расширение имени — только когда содержимое молчит.
pub fn detect(name: []const u8, bytes: []const u8) Kind {
    const head = bytes[0..@min(bytes.len, 2048)];
    if (looksPdf(bytes)) return .pdf;
    if (looksDjvu(bytes)) return .djvu;
    if (epub.looksLike(bytes)) return .epub; // любой ZIP: EPUB это или нет, скажет разбор
    if (std.mem.indexOf(u8, head, "<FictionBook") != null or std.mem.indexOf(u8, head, "<\x00F\x00i\x00c\x00t\x00i\x00o\x00n\x00B\x00o\x00o\x00k") != null) return .fb2;
    if (hasExt(name, ".fb2")) return .fb2;
    if (hasExt(name, ".epub")) return .epub;
    if (hasExt(name, ".pdf")) return .pdf;
    if (hasExt(name, ".djvu") or hasExt(name, ".djv")) return .djvu;
    return .txt;
}

/// Понимает ли сборка каталога файл с таким именем.
pub fn knownName(name: []const u8) bool {
    return hasExt(name, ".fb2") or hasExt(name, ".txt") or hasExt(name, ".epub") or hasExt(name, ".pdf") or hasExt(name, ".djvu") or hasExt(name, ".djv");
}

pub const Error = error{ OutOfMemory, TooBig, Damaged, NotFb2, NotEpub, Protected, NotPdf, Encrypted, NoText, Garbled, Disabled };

pub fn parse(a: std.mem.Allocator, kind: Kind, bytes: []const u8, budget: *Budget) Error!Parsed {
    const parsed: Parsed = switch (kind) {
        .fb2 => fb2.parse(a, bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotFb2 => error.NotFb2,
            else => error.Damaged,
        },
        .txt => fb2.parseTxt(a, bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TooBig,
        },
        .epub => try epub.parse(a, bytes, budget),
        .pdf => if (has_pdf) try pdf.parse(a, bytes, budget) else return error.Disabled,
        .djvu => if (has_djvu) try djvu.parse(a, bytes, budget) else return error.Disabled,
    };
    if (parsed.chapters.len == 0) return error.NoText;
    return parsed;
}

/// Причина отказа — фраза для того, кто выкладывал (windows-1251).
pub fn reason(err: Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => cp.text("Не хватило памяти на разбор файла."),
        error.TooBig => cp.text("Файл слишком велик после распаковки."),
        error.Damaged => cp.text("Файл повреждён и не разбирается."),
        error.NotFb2 => cp.text("Файл FB2 не разобран."),
        error.NotEpub => cp.text("Это не книга EPUB: в архиве нет описания или текста."),
        error.Protected => cp.text("Книга EPUB защищена от копирования (DRM): её текст зашифрован."),
        error.NotPdf => cp.text("Файл PDF не разобран: в нём не нашлось страниц."),
        error.Encrypted => cp.text("Файл PDF закрыт паролем или защитой: текст из него не достаётся."),
        error.NoText => cp.text("В файле нет текста. Если это скан, то в нём только картинки страниц, а распознавания текста на сайте нет."),
        error.Garbled => cp.text("Текст в файле PDF есть, но его буквы не переводятся в обычные: шрифты вложены без таблицы соответствия."),
        error.Disabled => cp.text("Разбор этого формата в программу не собран."),
    };
}

fn oneLine(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| if (c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return std.mem.trim(u8, out, " ");
}

/// Книга в виде канонического текстового файла сайта (UTF-8): шапка
/// `#clipper-book` с описанием, главы — строками «## Название». Этот файл
/// читает `fb2.parseTxt`.
pub fn canonical(a: std.mem.Allocator, p: Parsed, uploader: i32) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.print("#clipper-book\ntitle: {s}\n", .{try oneLine(a, p.title)});
    if (p.author_id != 0) try w.print("author: {d}\n", .{p.author_id}) else if (p.author.len > 0) try w.print("author-name: {s}\n", .{try oneLine(a, p.author)});
    if (uploader != 0) try w.print("uploader: {d}\n", .{uploader});
    if (p.series.len > 0) try w.print("series: {s}\n", .{try oneLine(a, p.series)});
    if (p.year.len > 0) try w.print("year: {s}\n", .{try oneLine(a, p.year)});
    try w.print("annotation: {s}\n\n", .{if (p.annotation.len > 0) try oneLine(a, p.annotation) else cp.text("—")});
    const single = p.chapters.len == 1 and std.mem.eql(u8, p.chapters[0].title, cp.text("Текст"));
    for (p.chapters) |ch| {
        if (!single) try w.print("## {s}\n\n", .{try oneLine(a, ch.title)});
        // строка текста, начинающаяся с «##», не должна стать заголовком главы
        var lines = std.mem.splitScalar(u8, ch.text, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and line[0] == 1) continue; // метка картинки
            if (std.mem.startsWith(u8, line, "##")) try out.append(' ');
            try out.appendSlice(line);
            try out.append('\n');
        }
        try out.append('\n');
    }
    return cp.toUtf8Alloc(a, out.items);
}

test "формат по содержимому и каноническая запись туда-обратно" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Kind.pdf, detect("book.txt", "%PDF-1.4\n"));
    try std.testing.expectEqual(Kind.epub, detect("book", "PK\x03\x04\x14\x00"));
    try std.testing.expectEqual(Kind.fb2, detect("x.bin", "<?xml version=\"1.0\"?><FictionBook>"));
    try std.testing.expectEqual(Kind.djvu, detect("x", "AT&TFORM\x00\x00\x00\x10DJVU"));
    try std.testing.expectEqual(Kind.txt, detect("x.txt", "просто текст"));
    try std.testing.expectEqual(Kind.pdf, detect("x.PDF", ""));
    try std.testing.expect(knownName("a.EPUB") and !knownName("a.doc"));

    const book = Parsed{
        .title = cp.text("Степь\nи море"),
        .author = cp.text("Антон Чехов"),
        .series = cp.text("Повести"),
        .year = "1888",
        .annotation = cp.text("Про дорогу."),
        .chapters = &.{
            .{ .title = cp.text("I"), .text = cp.text("Первый абзац.\n\n## не заголовок\nстрока") },
            .{ .title = cp.text("Глава вторая"), .text = cp.text("Второй.") },
        },
    };
    const file = try canonical(a, book, 1001);
    const back = try fb2.parseTxt(a, file);
    try std.testing.expectEqualStrings(cp.text("Степь и море"), back.title);
    try std.testing.expectEqualStrings(cp.text("Антон Чехов"), back.author);
    try std.testing.expectEqualStrings(cp.text("Повести"), back.series);
    try std.testing.expectEqualStrings("1888", back.year);
    try std.testing.expectEqual(@as(i32, 1001), back.uploader);
    try std.testing.expectEqual(@as(usize, 2), back.chapters.len);
    try std.testing.expectEqualStrings(cp.text("I"), back.chapters[0].title);
    try std.testing.expectEqualStrings(cp.text("Первый абзац.\n\n ## не заголовок\nстрока"), back.chapters[0].text);
    try std.testing.expectEqualStrings(cp.text("Второй."), back.chapters[1].text);
    var budget = Budget{ .left = 1 << 20 };
    try std.testing.expectError(if (has_djvu) error.Damaged else error.Disabled, parse(a, .djvu, "AT&TFORM", &budget));
    try std.testing.expectError(error.NoText, parse(a, .txt, "  \n ", &budget));
}
