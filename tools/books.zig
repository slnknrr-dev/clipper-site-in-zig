//! Сборщик встроенных книг: файлы Markdown → модуль `books` для сервера.
//!
//!   books ВЫХОД.zig ФАЙЛ.md...
//!
//! `build.zig` запускает его сам (шаг сборки сервера) с файлами из
//! `src/books/ru/` (русский) или `src/books/` (английский). Имя файла —
//! `<книга>x<страница>-<тема>-<подтема>.md`: книга — номер на сайте (/b/N),
//! страницы идут по порядку имён. Первый файл книги начинается описанием:
//!
//!   ---
//!   title: Название
//!   year: 2026
//!   annotation: Аннотация одной строкой.
//!   ---
//!
//! Автор встроенных книг — администратор сайта /u/0. На выходе — исходник Zig,
//! где строки уже в windows-1251: сервер ничего не разбирает и не перекодирует.
//!
//! Из Markdown понимается немногое, и всё остальное — обычный текст:
//!
//!   ## Название        глава (страница чтения и строка оглавления)
//!   # Название         часть: сама по себе ничего не печатает
//!   ### Название       подзаголовок: отдельный абзац «§ Название»
//!   пустая строка      граница абзаца; строки абзаца склеиваются пробелом
//!   - пункт, 1. пункт  своя строка внутри абзаца («— пункт»)
//!   > цитата           своя строка, знак убирается
//!   | a | b |          строка таблицы: «a — b»; строка-разделитель пропускается
//!   ``` … ```          код: один абзац, строки как есть, отступы — неразрывные пробелы
//!   **жирный**, `код`  знаки убираются; [текст](адрес) → «текст (адрес)»
//!
//! Символ, которого нет в windows-1251, — ошибка сборки с файлом и строкой.

const std = @import("std");
const cp = @import("cp1251");

const Chapter = struct { title: []const u8, text: std.ArrayList(u8) };

var failed = false;

fn fail(file: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("books: {s}:{d}: " ++ fmt ++ "\n", .{ file, line } ++ args);
    failed = true;
}

/// UTF-8 → windows-1251; чего в кодировке нет — ошибка.
fn encode(a: std.mem.Allocator, file: []const u8, line: usize, utf8: []const u8) []const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < utf8.len) {
        const u, const l = cp.utf8Next(utf8, i);
        i += l;
        if (cp.fromUnicode(u)) |c| {
            out.append(c) catch @panic("OOM");
        } else {
            fail(file, line, "символа U+{X:0>4} нет в windows-1251", .{u});
            out.append('?') catch @panic("OOM");
        }
    }
    return out.items;
}

/// Убирает разметку внутри строки: **, `, [текст](адрес).
fn inlineMd(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '`') {
            i += 1;
            continue;
        }
        if (s[i] == '*' and i + 1 < s.len and s[i + 1] == '*') {
            i += 2;
            continue;
        }
        if (s[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i, ']')) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, close, ')')) |end| {
                        out.appendSlice(inlineMd(a, s[i + 1 .. close])) catch @panic("OOM");
                        out.appendSlice(" (") catch @panic("OOM");
                        out.appendSlice(s[close + 2 .. end]) catch @panic("OOM");
                        out.append(')') catch @panic("OOM");
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        out.append(s[i]) catch @panic("OOM");
        i += 1;
    }
    return out.items;
}

fn isNumbered(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i > 0 and i + 1 < s.len and s[i] == '.' and s[i + 1] == ' ';
}

fn isTableRule(s: []const u8) bool {
    for (s) |c| if (std.mem.indexOfScalar(u8, "|-: ", c) == null) return false;
    return true;
}

const Book = struct {
    a: std.mem.Allocator,
    chapters: std.ArrayList(Chapter),
    /// Текущий абзац (UTF-8); пуст — абзац не начат.
    para: std.ArrayList(u8),
    para_line: usize = 0,
    file: []const u8 = "",

    fn flush(b: *Book) void {
        if (b.para.items.len == 0) return;
        defer b.para.clearRetainingCapacity();
        if (b.chapters.items.len == 0) return fail(b.file, b.para_line, "текст до первой главы (## Название)", .{});
        const ch = &b.chapters.items[b.chapters.items.len - 1];
        if (ch.text.items.len > 0) ch.text.appendSlice("\n\n") catch @panic("OOM");
        ch.text.appendSlice(encode(b.a, b.file, b.para_line, b.para.items)) catch @panic("OOM");
    }

    /// Новая строка абзаца (`fresh`) или продолжение предыдущей.
    fn add(b: *Book, line_no: usize, fresh: bool, text: []const u8) void {
        if (b.para.items.len == 0) b.para_line = line_no else b.para.append(if (fresh) '\n' else ' ') catch @panic("OOM");
        b.para.appendSlice(text) catch @panic("OOM");
    }

    fn file_(b: *Book, name: []const u8, src: []const u8) void {
        b.file = name;
        var in_code = false;
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trimRight(u8, raw, "\r \t");
            if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```")) {
                b.flush();
                in_code = !in_code;
                continue;
            }
            if (in_code) {
                // Отступ — неразрывными пробелами: страница чтения пробелы схлопывает.
                var indent: usize = 0;
                var at: usize = 0;
                while (at < line.len and (line[at] == ' ' or line[at] == '\t')) : (at += 1) indent += if (line[at] == '\t') 4 else 1;
                if (b.para.items.len == 0) b.para_line = line_no else b.para.append('\n') catch @panic("OOM");
                for (0..@max(indent, @intFromBool(at == line.len))) |_| b.para.appendSlice("\u{A0}") catch @panic("OOM");
                b.para.appendSlice(line[at..]) catch @panic("OOM");
                continue;
            }
            if (line.len == 0) {
                b.flush();
                continue;
            }
            if (std.mem.startsWith(u8, line, "### ")) {
                b.flush();
                b.add(line_no, true, std.fmt.allocPrint(b.a, "§ {s}", .{inlineMd(b.a, line[4..])}) catch @panic("OOM"));
                b.flush();
            } else if (std.mem.startsWith(u8, line, "## ")) {
                b.flush();
                const title = encode(b.a, name, line_no, inlineMd(b.a, std.mem.trim(u8, line[3..], " ")));
                if (title.len == 0 or title.len > 200) fail(name, line_no, "название главы пусто или длиннее 200 знаков", .{});
                b.chapters.append(.{ .title = title, .text = std.ArrayList(u8).init(b.a) }) catch @panic("OOM");
            } else if (std.mem.startsWith(u8, line, "# ")) {
                b.flush();
            } else if (std.mem.startsWith(u8, line, "- ")) {
                b.add(line_no, true, std.fmt.allocPrint(b.a, "— {s}", .{inlineMd(b.a, line[2..])}) catch @panic("OOM"));
            } else if (std.mem.startsWith(u8, line, "> ")) {
                b.add(line_no, true, inlineMd(b.a, line[2..]));
            } else if (line[0] == '|') {
                if (isTableRule(line)) continue;
                var row = std.ArrayList(u8).init(b.a);
                var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, "| "), '|');
                while (cells.next()) |cell| {
                    if (row.items.len > 0) row.appendSlice(" — ") catch @panic("OOM");
                    row.appendSlice(inlineMd(b.a, std.mem.trim(u8, cell, " "))) catch @panic("OOM");
                }
                b.add(line_no, true, row.items);
            } else {
                b.add(line_no, isNumbered(line), inlineMd(b.a, std.mem.trimLeft(u8, line, " ")));
            }
        }
        if (in_code) fail(name, line_no, "блок ``` не закрыт", .{});
        b.flush();
    }
};

const Meta = struct { title: []const u8 = "", year: []const u8 = "", annotation: []const u8 = "" };

/// Описание книги в начале её первого файла; возвращает текст после него.
fn frontMatter(a: std.mem.Allocator, path: []const u8, src: []const u8, meta: *Meta) []const u8 {
    if (!std.mem.startsWith(u8, src, "---")) {
        fail(path, 1, "первый файл книги начинается описанием: ---, title, year, annotation, ---", .{});
        return src;
    }
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next();
    var n: usize = 1;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, "\r \t");
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            fail(path, n, "нужно «поле: значение»", .{});
            continue;
        };
        const k = line[0..colon];
        const v = encode(a, path, n, std.mem.trim(u8, line[colon + 1 ..], " "));
        if (std.mem.eql(u8, k, "title")) meta.title = v else if (std.mem.eql(u8, k, "year")) meta.year = v else if (std.mem.eql(u8, k, "annotation")) meta.annotation = v else fail(path, n, "неизвестное поле «{s}» (есть title, year, annotation)", .{k});
    } else fail(path, n, "описание книги не закрыто строкой ---", .{});
    if (meta.title.len == 0 or meta.annotation.len == 0) fail(path, n, "в описании нужны title и annotation", .{});
    return lines.rest();
}

/// Номер книги из имени файла: «12x03-тема.md» → 12.
fn bookOf(path: []const u8) ?u31 {
    const name = std.fs.path.basename(path);
    const x = std.mem.indexOfScalar(u8, name, 'x') orelse return null;
    return std.fmt.parseInt(u31, name[0..x], 10) catch null;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("books ВЫХОД.zig ФАЙЛ.md...\n", .{});
        std.process.exit(2);
    }
    const max = 16 << 20;

    // Файлы — по имени: книги по номеру, страницы по порядку.
    const files = argv[2..];
    std.mem.sort([:0]u8, files, {}, struct {
        fn lt(_: void, x: [:0]u8, y: [:0]u8) bool {
            const bx = bookOf(x) orelse 0;
            const by = bookOf(y) orelse 0;
            if (bx != by) return bx < by;
            return std.mem.order(u8, std.fs.path.basename(x), std.fs.path.basename(y)) == .lt;
        }
    }.lt);

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("//! Встроенные книги. Файл сделан tools/books.zig из src/books/ — руками не править.\n//! Строки — в windows-1251.\n");
    try w.writeAll("pub const Chapter = struct { title: []const u8, text: []const u8 };\n");
    try w.writeAll("pub const Book = struct { id: i32, title: []const u8, year: []const u8, annotation: []const u8, chapters: []const Chapter };\n");
    try w.writeAll("pub const list = [_]Book{\n");

    var i: usize = 0;
    while (i < files.len) {
        const id = bookOf(files[i]) orelse {
            fail(files[i], 0, "имя файла — <книга>x<страница>-<тема>-<подтема>.md", .{});
            i += 1;
            continue;
        };
        var meta = Meta{};
        var book = Book{ .a = a, .chapters = std.ArrayList(Chapter).init(a), .para = std.ArrayList(u8).init(a) };
        const first = files[i];
        while (i < files.len and bookOf(files[i]) == id) : (i += 1) {
            var src: []const u8 = try std.fs.cwd().readFileAlloc(a, files[i], max);
            if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];
            if (files[i].ptr == first.ptr) src = frontMatter(a, files[i], src, &meta);
            book.file_(files[i], src);
        }
        for (book.chapters.items) |ch| {
            if (ch.text.items.len == 0) fail(first, 0, "глава без текста: {s}", .{ch.title});
        }
        if (book.chapters.items.len == 0) fail(first, 0, "в книге {d} нет ни одной главы", .{id});
        try w.print("    .{{ .id = {d}, .title = \"{}\", .year = \"{}\", .annotation = \"{}\", .chapters = &.{{\n", .{ id, std.zig.fmtEscapes(meta.title), std.zig.fmtEscapes(meta.year), std.zig.fmtEscapes(meta.annotation) });
        for (book.chapters.items) |ch| try w.print("        .{{ .title = \"{}\", .text = \"{}\" }},\n", .{ std.zig.fmtEscapes(ch.title), std.zig.fmtEscapes(ch.text.items) });
        try w.writeAll("    } },\n");
    }
    try w.writeAll("};\n");
    if (failed) std.process.exit(1);
    try std.fs.cwd().writeFile(.{ .sub_path = argv[1], .data = out.items });
}
