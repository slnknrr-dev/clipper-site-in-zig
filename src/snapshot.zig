//! Снимок каталога: один неизменяемый файл `library.N.snap` с книгами,
//! сериями, стихами и людьми в том виде, в каком их читает сервер —
//! таблицы отсортированы, строки уже в windows-1251. Сервер отображает файл
//! в память и не разбирает его: «найти» — это срез отображения.
//!
//! Текст книг лежит кадрами: страницы чтения режутся на кадры по 16 КБ,
//! каждый сжат отдельно (deflate из std). Страница чтения — это 1–2 кадра.
//! С -zstd кадры сжаты своим zstd со словарём из файла clipper<N>.zstd, и
//! размер кадра (4–32 КБ) — из того же файла (zfile.zig).
//!
//!   Header | кадры … | books | series | pieces | persons | pages | frames | list | images | blob
//!
//! Картинки книг лежат не в снимке, а в общем хранилище img/b/ (imgstore.zig):
//! в снимке — таблица ссылок (отпечаток, вид, размер, подпись), в тексте главы
//! на месте картинки — абзац «\x01N» с номером строки этой таблицы.
//!
//! Все целые — little-endian, разделы выровнены на 8 байт. Какой файл в
//! работе, сказано в `library.current`.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const config = @import("config");
/// Свой zstd — только при -Dzstd=true (по умолчанию).
pub const zstd = if (config.zstd) @import("zstd.zig") else struct {};
pub const zfile = @import("zfile.zig");

/// Словарь zstd этого процесса (из файла, -zstd). Снимок со zstd читается и
/// собирается только с ним; ставит его App.init или clipper build.
pub var active: zfile.Dict = .{};

/// Собран ли zstd в программу (-Dzstd).
pub const has_zstd = config.zstd;

/// Чем сжаты кадры снимка. zstd — со словарём из файла (active).
pub const Codec = enum(u32) { deflate = 0, zstd = 1 };

/// Отпечаток словаря (вместе с размером кадра): снимок со zstd читается только с тем же.
pub fn dictHash() u32 {
    return active.hash;
}

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("формат снимка — little-endian");
}

pub const magic = "CLIPSNAP".*;
pub const version: u32 = 6;
/// Кадр deflate; кадр zstd — из файла словаря, не больше frame_max.
pub const frame_bytes = 16 * 1024;
pub const frame_max = zfile.max_kb * 1024;
/// Страница чтения — не больше 32 КБ (кроме одного огромного абзаца) при любом кадре.
pub const page_bytes = 32 * 1024;
pub const pointer_name = "library.current";

pub const Span = extern struct { off: u32 = 0, len: u32 = 0 };
pub const Range = extern struct { off: u32 = 0, len: u32 = 0 };

pub const Header = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    gen: u32 = 0,
    built: i64 = 0,
    n_books: u32 = 0,
    n_series: u32 = 0,
    n_pieces: u32 = 0,
    n_persons: u32 = 0,
    n_pages: u32 = 0,
    n_frames: u32 = 0,
    n_list: u32 = 0,
    crc: u32 = 0,
    off_books: u64 = 0,
    off_series: u64 = 0,
    off_pieces: u64 = 0,
    off_persons: u64 = 0,
    off_pages: u64 = 0,
    off_frames: u64 = 0,
    off_list: u64 = 0,
    off_blob: u64 = 0,
    blob_len: u64 = 0,
    off_data: u64 = 0,
    data_len: u64 = 0,
    /// порядок показа (порядок создания) — номера в `list`
    ord_books: Range = .{},
    ord_pieces: Range = .{},
    /// чем сжаты кадры (Codec) и отпечаток словаря zstd
    codec: u32 = 0,
    dict_hash: u32 = 0,
    /// размер кадра, КБ
    frame_kb: u32 = frame_bytes / 1024,
    n_images: u32 = 0,
    off_images: u64 = 0,
};

pub const Book = extern struct {
    id: i32,
    author: i32,
    /// 0 — книга вне серий
    series: i32 = 0,
    /// 0 — никто (книга из исходной библиотеки)
    uploader: i32 = 0,
    title: Span = .{},
    year: Span = .{},
    annotation: Span = .{},
    /// из каких черновиков собрана (в `list`)
    drafts: Range = .{},
    first_page: u32 = 0,
    n_pages: u32 = 0,
    text_len: u32 = 0,
    /// обложка: номер картинки + 1; 0 — обложки нет
    cover: u32 = 0,
};

pub const Page = extern struct { title: Span = .{}, first_frame: u32 = 0, n_frames: u32 = 0, n_paras: u32 = 0, len: u32 = 0 };
pub const Frame = extern struct { off: u64, clen: u32, rlen: u32 };
pub const Series = extern struct { id: i32, author: i32, title: Span = .{}, about: Span = .{}, books: Range = .{} };
/// Стих или песня. uploader — кто выложил (0 — никто: из заготовки или черновика);
/// flags: 1 — текст в ChordPro (аккорды в словах).
pub const Piece = extern struct { id: i32, author: i32, title: Span = .{}, genre: Span = .{}, year: Span = .{}, text: Span = .{}, chords: Span = .{}, notes: Span = .{}, uploader: i32 = 0, flags: u32 = 0 };
pub const piece_chordpro: u32 = 1;
pub const Person = extern struct { id: i32, _pad: u32 = 0, name: Span = .{}, years: Span = .{}, about: Span = .{} };
/// Картинка книги в хранилище img/b/: файл «{hash:0>16x}.jpg|png».
pub const Image = extern struct { hash: u64, w: u16, h: u16, kind: u8, _pad: [3]u8 = .{ 0, 0, 0 }, caption: Span = .{} };

/// Порядок таблиц и показа: сначала положительные по возрастанию, потом
/// отрицательные по возрастанию модуля (то есть в порядке создания).
pub fn ord(id: i32) u32 {
    return if (id >= 0) @intCast(id) else 0x8000_0000 + @as(u32, @intCast(-@as(i64, id)));
}

fn find(comptime T: type, items: []const T, id: i32) ?*const T {
    var lo: usize = 0;
    var hi: usize = items.len;
    const want = ord(id);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const have = ord(items[mid].id);
        if (have == want) return &items[mid];
        if (have < want) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub const Snapshot = struct {
    map: sys.Mapping,
    h: *const Header,
    books: []const Book,
    series: []const Series,
    pieces: []const Piece,
    persons: []const Person,
    pages: []const Page,
    frames: []const Frame,
    list: []const i32,
    images: []const Image = &.{},
    blob: []const u8,
    data: []const u8,
    book_order: []const i32 = &.{},
    piece_order: []const i32 = &.{},

    fn table(comptime T: type, bytes: []align(8) const u8, off: u64, n: u32) ![]const T {
        const len = @as(u64, n) * @sizeOf(T);
        if (off % 8 != 0 or off > bytes.len or len > bytes.len - off) return error.Damaged;
        const part: []align(8) const u8 = @alignCast(bytes[@intCast(off)..][0..@intCast(len)]);
        return std.mem.bytesAsSlice(T, part);
    }

    /// Открывает и проверяет файл целиком: битый снимок не доходит до запросов.
    pub fn open(dir: std.fs.Dir, name: []const u8) !Snapshot {
        var map = try sys.Mapping.open(dir, name);
        errdefer map.close();
        const bytes: []align(8) const u8 = @alignCast(map.bytes);
        if (bytes.len < @sizeOf(Header)) return error.Damaged;
        const h: *const Header = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &h.magic, &magic) or h.version != version) return error.Damaged;
        // кадры zstd читаются только сборкой с zstd и тем же словарём
        if (h.codec == @intFromEnum(Codec.zstd) and (!config.zstd or h.dict_hash != active.hash or h.frame_kb != active.frame_kb)) return error.Damaged;
        if (h.codec > 1) return error.Damaged;
        if (h.codec == @intFromEnum(Codec.deflate) and h.frame_kb != frame_bytes / 1024) return error.Damaged;
        const fb = @as(u64, h.frame_kb) * 1024;
        var s = Snapshot{
            .map = map,
            .h = h,
            .books = try table(Book, bytes, h.off_books, h.n_books),
            .series = try table(Series, bytes, h.off_series, h.n_series),
            .pieces = try table(Piece, bytes, h.off_pieces, h.n_pieces),
            .persons = try table(Person, bytes, h.off_persons, h.n_persons),
            .pages = try table(Page, bytes, h.off_pages, h.n_pages),
            .frames = try table(Frame, bytes, h.off_frames, h.n_frames),
            .list = try table(i32, bytes, h.off_list, h.n_list),
            .images = try table(Image, bytes, h.off_images, h.n_images),
            .blob = try table(u8, bytes, h.off_blob, std.math.cast(u32, h.blob_len) orelse return error.Damaged),
            .data = undefined,
        };
        if (h.off_data > bytes.len or h.data_len > bytes.len - h.off_data) return error.Damaged;
        s.data = bytes[@intCast(h.off_data)..][0..@intCast(h.data_len)];
        if (h.crc != s.tablesCrc()) return error.Damaged;
        s.book_order = s.ids(h.ord_books);
        s.piece_order = s.ids(h.ord_pieces);
        if (s.book_order.len != s.books.len or s.piece_order.len != s.pieces.len) return error.Damaged;
        for (s.books) |b| {
            if (@as(u64, b.first_page) + b.n_pages > s.pages.len) return error.Damaged;
            if (b.cover > s.images.len) return error.Damaged;
        }
        for (s.pages) |p| {
            if (@as(u64, p.first_frame) + p.n_frames > s.frames.len) return error.Damaged;
        }
        for (s.frames) |f| {
            if (f.off > s.data.len or f.clen > s.data.len - f.off or f.rlen > fb or f.clen > fb) return error.Damaged;
        }
        return s;
    }

    pub fn close(s: *Snapshot) void {
        s.map.close();
    }

    fn tablesCrc(s: *const Snapshot) u32 {
        var c = std.hash.Crc32.init();
        c.update(std.mem.sliceAsBytes(s.books));
        c.update(std.mem.sliceAsBytes(s.series));
        c.update(std.mem.sliceAsBytes(s.pieces));
        c.update(std.mem.sliceAsBytes(s.persons));
        c.update(std.mem.sliceAsBytes(s.pages));
        c.update(std.mem.sliceAsBytes(s.frames));
        c.update(std.mem.sliceAsBytes(s.list));
        c.update(std.mem.sliceAsBytes(s.images));
        c.update(s.blob);
        return c.final();
    }

    pub fn str(s: *const Snapshot, sp: Span) []const u8 {
        if (sp.off > s.blob.len or sp.len > s.blob.len - sp.off) return "";
        return s.blob[sp.off..][0..sp.len];
    }

    pub fn ids(s: *const Snapshot, r: Range) []const i32 {
        if (r.off > s.list.len or r.len > s.list.len - r.off) return &.{};
        return s.list[r.off..][0..r.len];
    }

    pub fn book(s: *const Snapshot, id: i32) ?*const Book {
        return if (id < 0) null else find(Book, s.books, id);
    }
    pub fn oneSeries(s: *const Snapshot, id: i32) ?*const Series {
        return find(Series, s.series, id);
    }
    pub fn piece(s: *const Snapshot, id: i32) ?*const Piece {
        return find(Piece, s.pieces, id);
    }
    pub fn person(s: *const Snapshot, id: i32) ?*const Person {
        return find(Person, s.persons, id);
    }

    /// Картинка по номеру из метки текста; null — нет такой.
    pub fn image(s: *const Snapshot, i: u32) ?*const Image {
        return if (i < s.images.len) &s.images[i] else null;
    }

    pub fn cover(s: *const Snapshot, b: *const Book) ?*const Image {
        return if (b.cover > 0) s.image(b.cover - 1) else null;
    }

    pub fn bookPages(s: *const Snapshot, b: *const Book) []const Page {
        return s.pages[b.first_page..][0..b.n_pages];
    }

    /// Книги в порядке показа — порядке создания (как в макете: демо-книги,
    /// книга о сайте, затем выложенные).
    pub fn bookAt(s: *const Snapshot, k: usize) *const Book {
        return s.book(s.book_order[k]) orelse &s.books[k];
    }

    /// Стихи и песни в порядке создания.
    pub fn pieceAt(s: *const Snapshot, k: usize) *const Piece {
        return s.piece(s.piece_order[k]) orelse &s.pieces[k];
    }

    /// Распаковывает кадр `i` в `out`.
    pub fn frame(s: *const Snapshot, i: u32, out: *[frame_max]u8) ![]const u8 {
        const f = s.frames[i];
        const src = s.data[@intCast(f.off)..][0..f.clen];
        if (f.clen == f.rlen) {
            @memcpy(out[0..f.rlen], src);
            return out[0..f.rlen];
        }
        if (config.zstd and s.h.codec == @intFromEnum(Codec.zstd)) {
            const n = zstd.decompress(out[0..], src, active.bytes) catch return error.Damaged;
            if (n != f.rlen) return error.Damaged;
            return out[0..f.rlen];
        }
        var in = std.io.fixedBufferStream(src);
        var dst = std.io.fixedBufferStream(out[0..]);
        std.compress.flate.decompress(in.reader(), dst.writer()) catch return error.Damaged;
        if (dst.pos != f.rlen) return error.Damaged;
        return out[0..f.rlen];
    }
};

/// Находит словарь по флагу -zstd и делает его словарём процесса (active).
/// `.off` — null: словаря нет, кадры — deflate. Без числа сначала ищется словарь,
/// с которым собран текущий снимок в `root`. Освобождает Loaded.deinit.
pub fn useDict(gpa: std.mem.Allocator, root: std.fs.Dir, spec: zfile.Spec) zfile.Error!?zfile.Loaded {
    if (spec == .off) {
        active = .{};
        return null;
    }
    if (!config.zstd) return error.NoDict;
    const want: u32 = if (currentHeader(root)) |h| (if (h.codec == @intFromEnum(Codec.zstd)) h.dict_hash else 0) else 0;
    const l = try zfile.resolve(gpa, spec, want, &zfile.problem);
    active = l.dict;
    return l;
}

/// Заголовок снимка в работе без проверки файла (null — снимка нет или он
/// не этой версии): по нему -zstd выбирает словарь, с которым снимок собран.
pub fn currentHeader(dir: std.fs.Dir) ?Header {
    var name_buf: [64]u8 = undefined;
    const name = current(dir, &name_buf) orelse return null;
    const f = dir.openFile(name, .{}) catch return null;
    defer f.close();
    var h: Header = undefined;
    if ((f.readAll(std.mem.asBytes(&h)) catch return null) != @sizeOf(Header)) return null;
    if (!std.mem.eql(u8, &h.magic, &magic) or h.version != version) return null;
    return h;
}

/// Имя снимка в работе (из `library.current`); null — снимков ещё нет.
pub fn current(dir: std.fs.Dir, buf: *[64]u8) ?[]const u8 {
    const raw = dir.readFile(pointer_name, buf) catch return null;
    const name = std.mem.trim(u8, raw, " \r\n");
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    return name;
}

pub fn genOf(name: []const u8) u32 {
    // library.N.snap
    var it = std.mem.splitScalar(u8, name, '.');
    _ = it.next();
    return std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
}

// ───────────── сборка ─────────────

pub const InChapter = struct { title: []const u8, text: []const u8 };
/// Картинка книги, уже лежащая в хранилище (imgstore.put).
pub const InImage = struct { hash: u64, w: u16, h: u16, kind: u8, caption: []const u8 = "" };
pub const InBook = struct {
    id: i32,
    author: i32,
    series: i32 = 0,
    uploader: i32 = 0,
    title: []const u8,
    year: []const u8 = "",
    annotation: []const u8 = "",
    drafts: []const i32 = &.{},
    chapters: []const InChapter,
    /// картинки по номерам меток текста; null — картинка не обработалась (метка уходит)
    images: []const ?InImage = &.{},
    cover: ?u32 = null,
};

/// Абзацы-метки картинок «\x01k» (k — номер в книге) → «\x01g» (номер в снимке);
/// метки несуществующих и необработанных картинок убираются вместе с абзацем.
fn renumber(a: std.mem.Allocator, text: []const u8, global: []const ?u32) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 1) == null) return text;
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitSequence(u8, text, "\n\n");
    while (it.next()) |p| {
        var keep = p;
        var buf: [16]u8 = undefined;
        if (p.len >= 2 and p[0] == 1) {
            const k = std.fmt.parseInt(usize, p[1..], 10) catch std.math.maxInt(usize);
            const g = if (k < global.len) global[k] else null;
            keep = if (g) |x| std.fmt.bufPrint(&buf, "\x01{d}", .{x}) catch unreachable else "";
        }
        if (keep.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice("\n\n");
        try out.appendSlice(keep);
    }
    return out.items;
}
pub const InSeries = struct { id: i32, author: i32, title: []const u8, about: []const u8 = "", books: []const i32 = &.{} };
pub const InPiece = struct { id: i32, author: i32, title: []const u8, genre: []const u8 = "", year: []const u8 = "", text: []const u8, chords: []const u8 = "", notes: []const u8 = "", uploader: i32 = 0, chordpro: bool = false };
pub const InPerson = struct { id: i32, name: []const u8, years: []const u8 = "", about: []const u8 = "" };

/// Приводит текст главы к каноническому виду: \n как перевод строки, абзацы
/// разделены ровно одной пустой строкой, по краям пусто.
pub fn normalize(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, text.len);
    var n: usize = 0;
    var nl: usize = 0;
    for (text) |c| {
        if (c == '\r') continue;
        if (c == '\n') {
            nl += 1;
            continue;
        }
        if (nl > 0 and n > 0) {
            out[n] = '\n';
            n += 1;
            if (nl > 1) {
                out[n] = '\n';
                n += 1;
            }
        }
        nl = 0;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

pub fn countParas(text: []const u8) u32 {
    if (text.len == 0) return 0;
    return @intCast(std.mem.count(u8, text, "\n\n") + 1);
}

/// n-й абзац канонического текста.
pub fn para(text: []const u8, n: usize) ?[]const u8 {
    var it = std.mem.splitSequence(u8, text, "\n\n");
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) if (i == n) return p;
    return null;
}

pub const Builder = struct {
    gpa: std.mem.Allocator,
    file: std.fs.File,
    data_len: u64 = 0,
    books: std.ArrayListUnmanaged(Book) = .{},
    series: std.ArrayListUnmanaged(Series) = .{},
    pieces: std.ArrayListUnmanaged(Piece) = .{},
    persons: std.ArrayListUnmanaged(Person) = .{},
    pages: std.ArrayListUnmanaged(Page) = .{},
    frames: std.ArrayListUnmanaged(Frame) = .{},
    list: std.ArrayListUnmanaged(i32) = .{},
    blob: std.ArrayListUnmanaged(u8) = .{},
    book_order: std.ArrayListUnmanaged(i32) = .{},
    piece_order: std.ArrayListUnmanaged(i32) = .{},
    images: std.ArrayListUnmanaged(Image) = .{},
    raw_bytes: u64 = 0,
    codec: Codec = .deflate,
    /// размер кадра: 16 КБ у deflate, из словаря у zstd
    fb: usize = frame_bytes,
    /// память для сжатия zstd (кадры сжимаются по одному)
    zarena: std.heap.ArenaAllocator = undefined,

    const data_off = std.mem.alignForward(u64, @sizeOf(Header), 8);

    pub fn init(gpa: std.mem.Allocator, dir: std.fs.Dir, name: []const u8, codec: Codec) !Builder {
        if (codec == .zstd and (!config.zstd or active.hash == 0)) return error.NoZstd;
        const file = try dir.createFile(name, .{ .read = true });
        try file.seekTo(data_off);
        return .{ .gpa = gpa, .file = file, .codec = codec, .fb = if (codec == .zstd) active.frameBytes() else frame_bytes, .zarena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(b: *Builder) void {
        b.books.deinit(b.gpa);
        b.series.deinit(b.gpa);
        b.pieces.deinit(b.gpa);
        b.persons.deinit(b.gpa);
        b.pages.deinit(b.gpa);
        b.frames.deinit(b.gpa);
        b.list.deinit(b.gpa);
        b.blob.deinit(b.gpa);
        b.book_order.deinit(b.gpa);
        b.piece_order.deinit(b.gpa);
        b.images.deinit(b.gpa);
        b.zarena.deinit();
        b.file.close();
    }

    fn span(b: *Builder, s: []const u8) !Span {
        if (s.len == 0) return .{};
        const off: u32 = std.math.cast(u32, b.blob.items.len) orelse return error.TooBig;
        try b.blob.appendSlice(b.gpa, s);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    fn range(b: *Builder, v: []const i32) !Range {
        const off: u32 = @intCast(b.list.items.len);
        try b.list.appendSlice(b.gpa, v);
        return .{ .off = off, .len = @intCast(v.len) };
    }

    fn addFrame(b: *Builder, raw: []const u8) !void {
        var buf: [frame_max + 512]u8 = undefined;
        var in = std.io.fixedBufferStream(raw);
        var dst = std.io.fixedBufferStream(&buf);
        var stored = raw;
        if (config.zstd and b.codec == .zstd) {
            defer _ = b.zarena.reset(.retain_capacity);
            if (zstd.compress(b.zarena.allocator(), raw, active.bytes, .{})) |z| {
                if (z.len < raw.len and z.len <= buf.len) {
                    @memcpy(buf[0..z.len], z);
                    stored = buf[0..z.len];
                }
            } else |_| {}
        } else if (std.compress.flate.compress(in.reader(), dst.writer(), .{})) |_| {
            if (dst.pos < raw.len) stored = buf[0..dst.pos];
        } else |_| {}
        try b.file.writeAll(stored);
        try b.frames.append(b.gpa, .{ .off = b.data_len, .clen = @intCast(stored.len), .rlen = @intCast(raw.len) });
        b.data_len += stored.len;
        b.raw_bytes += raw.len;
    }

    fn addPage(b: *Builder, title: []const u8, text: []const u8) !void {
        const first: u32 = @intCast(b.frames.items.len);
        var at: usize = 0;
        while (at < text.len) {
            const n = @min(b.fb, text.len - at);
            try b.addFrame(text[at..][0..n]);
            at += n;
        }
        try b.pages.append(b.gpa, .{
            .title = try b.span(title),
            .first_frame = first,
            .n_frames = @intCast(b.frames.items.len - first),
            .n_paras = countParas(text),
            .len = @intCast(text.len),
        });
    }

    pub fn addBook(b: *Builder, in: InBook) !void {
        const first_page: u32 = @intCast(b.pages.items.len);
        var text_len: u64 = 0;
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // картинки книги → строки таблицы снимка; номер в книге → номер в снимке
        const global = try a.alloc(?u32, in.images.len);
        for (in.images, global) |im, *g| {
            g.* = null;
            const x = im orelse continue;
            g.* = std.math.cast(u32, b.images.items.len) orelse continue;
            try b.images.append(b.gpa, .{ .hash = x.hash, .w = x.w, .h = x.h, .kind = x.kind, .caption = try b.span(x.caption) });
        }
        const cover: u32 = if (in.cover) |k| (if (k < global.len) (if (global[k]) |g| g + 1 else 0) else 0) else 0;
        for (in.chapters) |ch| {
            const text = try renumber(a, try normalize(a, ch.text), global);
            if (text.len == 0) continue;
            text_len += text.len;
            // Длинная глава — несколько страниц, по границам абзацев.
            var from: usize = 0;
            var part: u32 = 1;
            while (true) {
                var to = text.len;
                if (to - from > page_bytes) {
                    const window = text[from..][0..page_bytes];
                    to = if (std.mem.lastIndexOf(u8, window, "\n\n")) |cut| from + cut else blk: {
                        // один абзац длиннее страницы: до его конца
                        break :blk if (std.mem.indexOfPos(u8, text, from + page_bytes, "\n\n")) |e| e else text.len;
                    };
                    if (to == from) to = text.len;
                }
                const title = if (part == 1) ch.title else try std.fmt.allocPrint(a, "{s} ({d})", .{ ch.title, part });
                try b.addPage(title, text[from..to]);
                if (to >= text.len) break;
                from = to + 2;
                part += 1;
            }
        }
        try b.book_order.append(b.gpa, in.id);
        try b.books.append(b.gpa, .{
            .id = in.id,
            .author = in.author,
            .series = in.series,
            .uploader = in.uploader,
            .title = try b.span(in.title),
            .year = try b.span(in.year),
            .annotation = try b.span(in.annotation),
            .drafts = try b.range(in.drafts),
            .first_page = first_page,
            .n_pages = @intCast(b.pages.items.len - first_page),
            .text_len = std.math.cast(u32, text_len) orelse std.math.maxInt(u32),
            .cover = cover,
        });
    }

    pub fn addSeries(b: *Builder, in: InSeries) !void {
        try b.series.append(b.gpa, .{ .id = in.id, .author = in.author, .title = try b.span(in.title), .about = try b.span(in.about), .books = try b.range(in.books) });
    }

    pub fn addPiece(b: *Builder, in: InPiece) !void {
        try b.piece_order.append(b.gpa, in.id);
        try b.pieces.append(b.gpa, .{
            .id = in.id,
            .author = in.author,
            .title = try b.span(in.title),
            .genre = try b.span(in.genre),
            .year = try b.span(in.year),
            .text = try b.span(in.text),
            .chords = try b.span(in.chords),
            .notes = try b.span(in.notes),
            .uploader = in.uploader,
            .flags = if (in.chordpro) piece_chordpro else 0,
        });
    }

    pub fn addPerson(b: *Builder, in: InPerson) !void {
        try b.persons.append(b.gpa, .{ .id = in.id, .name = try b.span(in.name), .years = try b.span(in.years), .about = try b.span(in.about) });
    }

    fn byId(comptime T: type) fn (void, T, T) bool {
        return struct {
            fn lt(_: void, x: T, y: T) bool {
                return ord(x.id) < ord(y.id);
            }
        }.lt;
    }

    fn section(b: *Builder, c: *std.hash.Crc32, bytes: []const u8) !u64 {
        var pos = try b.file.getPos();
        const pad = std.mem.alignForward(u64, pos, 8) - pos;
        try b.file.writeAll(([_]u8{0} ** 8)[0..@intCast(pad)]);
        pos += pad;
        try b.file.writeAll(bytes);
        c.update(bytes);
        return pos;
    }

    /// Дописывает таблицы и заголовок; файл готов к отображению.
    pub fn finish(b: *Builder, gen: u32, now: i64) !void {
        std.mem.sort(Book, b.books.items, {}, byId(Book));
        std.mem.sort(Series, b.series.items, {}, byId(Series));
        std.mem.sort(Piece, b.pieces.items, {}, byId(Piece));
        std.mem.sort(Person, b.persons.items, {}, byId(Person));
        const ord_books = try b.range(b.book_order.items);
        const ord_pieces = try b.range(b.piece_order.items);
        var h = Header{
            .ord_books = ord_books,
            .ord_pieces = ord_pieces,
            .gen = gen,
            .built = now,
            .n_books = @intCast(b.books.items.len),
            .n_series = @intCast(b.series.items.len),
            .n_pieces = @intCast(b.pieces.items.len),
            .n_persons = @intCast(b.persons.items.len),
            .n_pages = @intCast(b.pages.items.len),
            .n_frames = @intCast(b.frames.items.len),
            .n_list = @intCast(b.list.items.len),
            .n_images = @intCast(b.images.items.len),
            .off_data = data_off,
            .data_len = b.data_len,
            .blob_len = b.blob.items.len,
            .codec = @intFromEnum(b.codec),
            .dict_hash = if (b.codec == .zstd) active.hash else 0,
            .frame_kb = @intCast(b.fb / 1024),
        };
        var c = std.hash.Crc32.init();
        h.off_books = try b.section(&c, std.mem.sliceAsBytes(b.books.items));
        h.off_series = try b.section(&c, std.mem.sliceAsBytes(b.series.items));
        h.off_pieces = try b.section(&c, std.mem.sliceAsBytes(b.pieces.items));
        h.off_persons = try b.section(&c, std.mem.sliceAsBytes(b.persons.items));
        h.off_pages = try b.section(&c, std.mem.sliceAsBytes(b.pages.items));
        h.off_frames = try b.section(&c, std.mem.sliceAsBytes(b.frames.items));
        h.off_list = try b.section(&c, std.mem.sliceAsBytes(b.list.items));
        h.off_images = try b.section(&c, std.mem.sliceAsBytes(b.images.items));
        h.off_blob = try b.section(&c, b.blob.items);
        h.crc = c.final();
        try b.file.pwriteAll(std.mem.asBytes(&h), 0);
        try b.file.sync();
    }
};

test "снимок: собрать, открыть, прочитать страницу" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var long = std.ArrayList(u8).init(gpa);
    defer long.deinit();
    for (0..900) |i| try long.writer().print("Абзац номер {d}, довольно длинный, чтобы глава заняла несколько кадров и страниц.\n\n", .{i});
    {
        var b = try Builder.init(gpa, tmp.dir, "library.1.snap", .deflate);
        defer b.deinit();
        try b.addPerson(.{ .id = 2, .name = "B" });
        try b.addPerson(.{ .id = 1, .name = "A" });
        try b.addBook(.{ .id = 7, .author = 1, .title = "Книга", .chapters = &.{ .{ .title = "I", .text = "раз\r\n\r\n\r\nдва\nтри" }, .{ .title = "II", .text = long.items } } });
        try b.addBook(.{ .id = 0, .author = 1, .title = "О сайте", .chapters = &.{.{ .title = "1", .text = "x" }} });
        try b.addSeries(.{ .id = -1, .author = 1, .title = "S", .books = &.{7} });
        try b.finish(1, 123);
    }
    var s = try Snapshot.open(tmp.dir, "library.1.snap");
    defer s.close();
    try std.testing.expectEqualStrings("A", s.str(s.person(1).?.name));
    const bk = s.book(7).?;
    try std.testing.expect(bk.n_pages > 3);
    const pg = s.bookPages(bk);
    try std.testing.expectEqual(@as(u32, 2), pg[0].n_paras);
    var buf: [frame_max]u8 = undefined;
    try std.testing.expectEqualStrings("раз\n\nдва\nтри", try s.frame(pg[0].first_frame, &buf));
    try std.testing.expectEqualStrings("II (2)", s.str(pg[2].title));
    for (pg[1..]) |p| try std.testing.expect(p.n_frames <= 2 and p.len <= page_bytes);
    const f1 = try s.frame(pg[1].first_frame, &buf);
    try std.testing.expect(std.mem.startsWith(u8, f1, "Абзац номер 0,"));
    try std.testing.expect(s.frames[pg[1].first_frame].clen < f1.len / 3);
    try std.testing.expectEqual(@as(i32, 7), s.ids(s.oneSeries(-1).?.books)[0]);
    try std.testing.expectEqual(@as(i32, 7), s.bookAt(0).id); // порядок показа — порядок добавления
    try std.testing.expectEqual(@as(i32, 0), s.bookAt(1).id);
    try std.testing.expect(s.book(8) == null);
}
