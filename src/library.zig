//! Сборка снимка каталога (`clipper build`, а также сам сервер — при первом
//! запуске и после выкладывания книги): встроенные книги, люди и стихи из
//! хранилища и файлы `books/` (FB2, txt) → `library.N.snap`, затем
//! `library.current` указывает на новый файл, и работающий сервер
//! подхватывает его без перезапуска.
//!
//! Номера устойчивы: какой файл какой книгой стал, под каким номером заведён
//! человек или серия — записано в хранилище (ключи m, n, q).

const std = @import("std");
const t9n = @import("t9n.zig");
const cp = @import("cp1251.zig");
const L = @import("ledger.zig");
const snap = @import("snapshot.zig");
const fb2 = @import("fb2.zig");
const import = @import("import.zig");
const dbm = @import("db.zig");
const sys = @import("sys.zig");
const config = @import("config");
const books = @import("books");
const imgstore = @import("imgstore.zig");

pub const books_dir = "books";
const max_file = 50 * 1024 * 1024;

/// Встроенные книги — в бинарнике: /b/0 (`-Dbook0`, по умолчанию есть) и
/// /b/1, /b/2, … (`-Dbooks`, по умолчанию нет). Текст собирает tools/books.zig
/// из `src/books/[ru/]`; автор — администратор сайта /u/0.
pub const has_book0 = config.book0;

/// Отпечаток встроенных книг. Снимок собран с ним и лежит в хранилище под
/// ключом Kbooks; не совпал — сервер при старте пересобирает снимок, иначе после
/// обновления программы на сайте оставались бы прежние книги.
pub fn booksMark(buf: *[16]u8, codec: snap.Codec) []const u8 {
    var h = std.hash.Wyhash.init(1);
    // способ сжатия и словарь — тоже часть отпечатка: сменились — снимок пересобирается
    h.update(std.mem.asBytes(&codec));
    if (codec == .zstd) h.update(std.mem.asBytes(&snap.dictHash()));
    for (books.list) |bk| {
        h.update(std.mem.asBytes(&bk.id));
        h.update(bk.title);
        h.update(bk.year);
        h.update(bk.annotation);
        for (bk.chapters) |ch| {
            h.update(ch.title);
            h.update(ch.text);
        }
    }
    return std.fmt.bufPrint(buf, "{x:0>16}", .{h.final()}) catch unreachable;
}

pub const Stats = struct { gen: u32, books: u32, files: u32, skipped: u32, raw: u64, packed_bytes: u64, images: usize = 0, images_new: usize = 0, images_failed: usize = 0 };

const Ctx = struct {
    a: std.mem.Allocator,
    l: *L.Ledger,
    b: *snap.Builder,
    persons: std.AutoHashMap(i32, void),
    series: std.AutoArrayHashMap(i32, SeriesAcc),

    const SeriesAcc = struct { author: i32, title: []const u8, about: []const u8 = "", books: std.ArrayListUnmanaged(i32) = .{} };

    fn lowerDup(c: *Ctx, s: []const u8) []u8 {
        const out = c.a.dupe(u8, s) catch return &.{};
        for (out) |*x| x.* = cp.lower(x.*);
        return out;
    }

    fn counter(c: *Ctx, comptime k: []const u8, first: i32, step: i32) i32 {
        const cur = if (c.l.get(c.a, "N" ++ k)) |v| std.fmt.parseInt(i32, v, 10) catch first else first;
        var buf: [16]u8 = undefined;
        c.l.put("N" ++ k, std.fmt.bufPrint(&buf, "{d}", .{cur + step}) catch unreachable);
        return cur;
    }

    /// Номер человека по имени; нового заводит. Номера участников не занимает.
    fn personId(c: *Ctx, name: []const u8) !i32 {
        const k = L.key(c.a, "n", .{c.lowerDup(name)});
        var id: i32 = 0;
        if (c.l.get(c.a, k)) |v| {
            id = std.fmt.parseInt(i32, v, 10) catch 0;
        }
        if (id == 0) {
            while (true) {
                id = c.counter("person", 5, 1);
                if (c.l.get(c.a, L.key(c.a, "U", .{id})) == null) break;
            }
            var buf: [16]u8 = undefined;
            c.l.put(k, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        }
        if (!c.persons.contains(id)) {
            try c.persons.put(id, {});
            try c.b.addPerson(.{ .id = id, .name = name });
        }
        return id;
    }

    fn seriesId(c: *Ctx, author: i32, title: []const u8) !i32 {
        const k = L.key(c.a, "q", .{ author, c.lowerDup(title) });
        var id: i32 = 0;
        if (c.l.get(c.a, k)) |v| id = std.fmt.parseInt(i32, v, 10) catch 0;
        if (id == 0) {
            id = c.counter("series", -3, -1);
            var buf: [16]u8 = undefined;
            c.l.put(k, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        }
        if (!c.series.contains(id)) try c.series.put(id, .{ .author = author, .title = title });
        return id;
    }

    fn fileId(c: *Ctx, name: []const u8) i32 {
        const k = L.key(c.a, "m", .{name});
        if (c.l.get(c.a, k)) |v| {
            if (std.fmt.parseInt(i32, v, 10)) |id| return id else |_| {}
        }
        // файл, сохранённый сайтом, называется своим номером
        const stem = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
        const own = std.fmt.parseInt(i32, stem, 10) catch 0;
        const id = if (own > 2 and std.mem.eql(u8, std.fmt.allocPrint(c.a, "{d}", .{own}) catch "", stem)) own else c.counter("book", 3, 1);
        var buf: [16]u8 = undefined;
        c.l.put(k, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        return id;
    }
};

/// Собирает новое поколение снимка.
/// `img` — папка картинок (-img или ROOTDIR/img): картинки книг ложатся в её b/.
pub fn build(gpa: std.mem.Allocator, root: std.fs.Dir, img: std.fs.Dir, l: *L.Ledger, codec: snap.Codec, log: bool) !Stats {
    var img_dir = try img.makeOpenPath(imgstore.dir_name, .{ .iterate = true });
    defer img_dir.close();
    var img_st = imgstore.Stats{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var name_buf: [64]u8 = undefined;
    const prev = if (snap.current(root, &name_buf)) |n| snap.genOf(n) else 0;
    const gen = prev + 1;
    const file_name = try std.fmt.allocPrint(a, "library.{d}.snap", .{gen});

    var b = try snap.Builder.init(gpa, root, file_name, codec);
    var b_open = true;
    defer if (b_open) b.deinit();
    errdefer root.deleteFile(file_name) catch {};
    var c = Ctx{ .a = a, .l = l, .b = &b, .persons = std.AutoHashMap(i32, void).init(a), .series = std.AutoArrayHashMap(i32, Ctx.SeriesAcc).init(a) };
    var st = Stats{ .gen = gen, .books = 0, .files = 0, .skipped = 0, .raw = 0, .packed_bytes = 0 };
    var seen_books = std.AutoHashMap(i32, void).init(a);

    // Номера 0, 1 и 2 принадлежат встроенным книгам при любой сборке: выложенная
    // книга их не получит, даже если встроенной под номером нет (-Dbook0, -Dbooks).
    inline for (.{ 0, 1, 2 }) |id| try seen_books.put(id, {});

    // Люди каталога с годами и описанием (ключ H): их заводят записями, в программе их нет.
    {
        var it = l.scan(a, "H");
        while (it.next()) |e| {
            const id = std.math.cast(i32, L.parseNum(e.key[1..])) orelse continue;
            const name = L.field(e.val, 0);
            try b.addPerson(.{ .id = id, .name = name, .years = L.field(e.val, 1), .about = L.field(e.val, 2) });
            try c.persons.put(id, {});
            var buf: [16]u8 = undefined;
            l.put(L.key(a, "n", .{c.lowerDup(name)}), std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        }
    }

    for (books.list) |bk| {
        const chapters = try a.alloc(fb2.Chapter, bk.chapters.len);
        for (chapters, bk.chapters) |*dst, ch| dst.* = .{ .title = ch.title, .text = ch.text };
        try b.addBook(.{ .id = bk.id, .author = 0, .title = bk.title, .year = bk.year, .annotation = bk.annotation, .chapters = chapters });
        st.books += 1;
    }

    // Стихи и песни из хранилища: перенесённые из черновиков (поля 0–4), песни с
    // нотами (5 — аккорды, 6 — ноты), порядок заведения (7), кто выложил (8) и
    // формат текста (9: «chordpro» — аккорды в словах). Без порядка — в конец,
    // в порядке ключей: так стих из черновика встаёт после заведённых раньше.
    {
        const Row = struct { seq: i64, p: snap.InPiece };
        var rows = std.ArrayList(Row).init(a);
        var it = l.scan(a, "p");
        while (it.next()) |e| {
            const seq_s = L.field(e.val, 7);
            try rows.append(.{ .seq = if (seq_s.len > 0) (std.fmt.parseInt(i64, seq_s, 10) catch std.math.maxInt(i64)) else std.math.maxInt(i64), .p = .{
                .id = std.math.cast(i32, L.parseNum(e.key[1..])) orelse continue,
                .title = L.field(e.val, 0),
                .author = std.math.cast(i32, L.fieldInt(e.val, 1)) orelse 0,
                .genre = L.field(e.val, 2),
                .year = L.field(e.val, 3),
                .text = L.field(e.val, 4),
                .chords = L.field(e.val, 5),
                .notes = L.field(e.val, 6),
                .uploader = std.math.cast(i32, L.fieldInt(e.val, 8)) orelse 0,
                .chordpro = std.mem.eql(u8, L.field(e.val, 9), "chordpro"),
            } });
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn lt(_: void, x: Row, y: Row) bool {
                return x.seq < y.seq;
            }
        }.lt);
        for (rows.items) |r| try b.addPiece(r.p);
    }

    // Файлы библиотеки, по именам.
    var names = std.ArrayList([]const u8).init(a);
    if (root.openDir(books_dir, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file) continue;
            if (!import.knownName(ent.name)) continue;
            try names.append(try a.dupe(u8, ent.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        // Номера раздаются по именам, а книги идут по номерам — в порядке появления.
        const Named = struct { id: i32, name: []const u8 };
        var numbered = std.ArrayList(Named).init(a);
        for (names.items) |name| try numbered.append(.{ .id = c.fileId(name), .name = name });
        std.mem.sort(Named, numbered.items, {}, struct {
            fn lt(_: void, x: Named, y: Named) bool {
                return x.id < y.id;
            }
        }.lt);
        for (numbered.items) |nm| {
            const name = nm.name;
            st.files += 1;
            // Память книги освобождается сразу: большая библиотека не должна жить в памяти целиком.
            var book_arena = std.heap.ArenaAllocator.init(gpa);
            defer book_arena.deinit();
            const ba = book_arena.allocator();
            const bytes = dir.readFileAlloc(ba, name, max_file) catch {
                st.skipped += 1;
                if (log) std.debug.print(t9n.tr("clipper build: {s}: не читается или больше 50 МБ, пропущен\n"), .{name});
                continue;
            };
            var budget = import.Budget{ .left = import.budget_bytes };
            const parsed = import.parse(ba, import.detect(name, bytes), bytes, &budget) catch |err| {
                st.skipped += 1;
                if (log) {
                    var why: [400]u8 = undefined;
                    std.debug.print(t9n.tr("clipper build: {s}: пропущен. {s}\n"), .{ name, why[0..cp.toUtf8(&why, import.reason(err))] });
                }
                continue;
            };
            const id = nm.id;
            if (seen_books.contains(id)) {
                st.skipped += 1;
                if (log) std.debug.print(t9n.tr("clipper build: {s}: номер {d} уже занят, пропущен\n"), .{ name, id });
                continue;
            }
            try seen_books.put(id, {});
            const stem = name[0 .. name.len - std.fs.path.extension(name).len];
            const title = if (parsed.title.len > 0) parsed.title else try cp.encodeAlloc(ba, stem);
            const author = if (parsed.author_id != 0) parsed.author_id else try c.personId(try a.dupe(u8, if (parsed.author.len > 0) parsed.author else cp.text("Неизвестный автор")));
            var series_id: i32 = 0;
            if (parsed.series.len > 0) {
                series_id = try c.seriesId(author, try a.dupe(u8, parsed.series));
                try c.series.getPtr(series_id).?.books.append(a, id);
            }
            // картинки — в хранилище img/b/ (готовые там только находятся)
            const ins = try ba.alloc(?snap.InImage, parsed.images.len);
            for (parsed.images, ins) |src, *dst| dst.* = imgstore.put(gpa, img_dir, src, &img_st);
            try b.addBook(.{
                .images = ins,
                .cover = parsed.cover,
                .id = id,
                .author = author,
                .series = series_id,
                .uploader = if (parsed.uploader != 0) parsed.uploader else if (l.get(ba, L.key(ba, "o", .{id}))) |v| (std.fmt.parseInt(i32, v, 10) catch 0) else 0,
                .title = title,
                .year = parsed.year,
                .annotation = if (parsed.annotation.len > 0) parsed.annotation else cp.text("—"),
                .drafts = parsed.drafts,
                .chapters = parsed.chapters,
            });
            st.books += 1;
        }
    } else |_| {}

    var sit = c.series.iterator();
    while (sit.next()) |e| try b.addSeries(.{ .id = e.key_ptr.*, .author = e.value_ptr.author, .title = e.value_ptr.title, .about = e.value_ptr.about, .books = e.value_ptr.books.items });

    var mark: [16]u8 = undefined;
    l.put("Kbooks", booksMark(&mark, codec));
    try b.finish(gen, sys.now());
    const new_images = try a.dupe(snap.Image, b.images.items);
    st.images = new_images.len;
    st.images_new = img_st.new;
    st.images_failed = img_st.failed;
    st.raw = b.raw_bytes;
    st.packed_bytes = b.data_len;
    b.deinit();
    b_open = false;
    try l.flush();

    // Указатель переключается последним: до этого сервер видит прежний снимок.
    try root.writeFile(.{ .sub_path = snap.pointer_name ++ ".tmp", .data = file_name });
    try root.rename(snap.pointer_name ++ ".tmp", snap.pointer_name);
    // Картинки, на которые не ссылаются ни новый, ни предыдущий снимок (его ещё
    // могут читать воркеры), убираются. Предыдущий не открылся — не убирается ничего.
    // фото профилей (ключи Y) лежат в том же хранилище
    const photos = (dbm.Db{ .l = l, .s = undefined, .a = a }).profilePhotos();
    sweep: {
        if (prev == 0) {
            imgstore.sweep(img_dir, &.{ new_images, photos });
            break :sweep;
        }
        const prev_name = std.fmt.allocPrint(a, "library.{d}.snap", .{prev}) catch break :sweep;
        var old = snap.Snapshot.open(root, prev_name) catch break :sweep;
        defer old.close();
        imgstore.sweep(img_dir, &.{ new_images, old.images, photos });
    }
    // Снимки старше предыдущего больше не нужны (занятый файл Windows не отдаст — не беда).
    if (gen > 2) {
        var g = gen - 2;
        var tries: u32 = 0;
        while (g > 0 and tries < 8) : ({
            g -= 1;
            tries += 1;
        }) {
            const old = std.fmt.allocPrint(a, "library.{d}.snap", .{g}) catch break;
            root.deleteFile(old) catch {};
        }
    }
    return st;
}
