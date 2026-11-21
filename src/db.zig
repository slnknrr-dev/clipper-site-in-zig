//! Модель данных поверх двух слоёв: каталог из снимка (книги, серии, стихи,
//! люди) и записи из `ledger` (всё, что пишут участники). Здесь — виды
//! ключей и разбор значений; страницы работают с готовыми структурами.
//!
//!   A логин            учётная запись     U ±N        участник
//!   S хеш              сеанс              K имя       настройка
//!   N имя              счётчик номеров    b ±N        счётчики и флаги книги
//!   C книга N          комментарий        D ±N        черновик / статья
//!   F N                форум              T форум N   тема       P тема N   сообщение
//!   B имя              доска              I доска:тред N         пост доски
//!   Q N                цитата             M участник N           закладка
//!   X -N               персонаж           p ±N        стих или песня каталога
//!   H N                человек каталога (имя, годы, о нём)
//!   m файл             номер книги файла  n имя       номер человека   q автор имя  номер серии
//!   G хеш              билет федерации (одноразовый, fed.zig)
//!   V +N               запись /v/N       V -N        чтец или исполнитель
//!   v участник         его чтецы          r имя       номер чтеца
//!   O вид N            источник произведения (вид: b книга, p стих, v запись, d статья)

const std = @import("std");
const L = @import("ledger.zig");
const snapshot = @import("snapshot.zig");
const cp1251 = @import("cp1251.zig");

pub const User = struct { id: i32, nick: []const u8, joined: []const u8, about: []const u8, login: []const u8 };
pub const Account = struct { login: []const u8, user: i32, hash: []const u8, rights: u8, blocked: bool };
pub const Person = struct { id: i32, name: []const u8, years: []const u8 = "", about: []const u8 = "", author: i32 = 0, books: []const u8 = "" };
/// Цитата. src: 'b' — книга (book, страница ch); 'p' — стих или песня (book — номер /p/N);
/// 'd' — статья (book — номер /d/N). para — абзац с нуля.
pub const Quote = struct { id: i32, person: i32, book: i32, ch: u32, para: u32, by: i32, date: []const u8, text: []const u8, src: u8 = 'b' };
pub const Bookmark = struct { id: i32, user: i32, book: i32, ch: u32, para: u32, date: []const u8, note: []const u8, text: []const u8 };
pub const Draft = struct {
    id: i32,
    title: []const u8,
    author: i32,
    created: []const u8,
    moved: []const u8,
    tags: []const u8,
    text: []const u8,
    /// порядковый номер создания (черновики и статьи вместе)
    seq: i64 = 0,
};
pub const Comment = struct { id: i32, parent: i32, author: i32, date: []const u8, text: []const u8 };
pub const Forum = struct { id: i32, title: []const u8, about: []const u8 };
pub const Topic = struct { id: i32, forum: i32, title: []const u8 };
pub const Post = struct { id: i32, topic: i32, author: i32, date: []const u8, forum: i32, text: []const u8 };
pub const Board = struct { id: []const u8, title: []const u8, ttl_min: i64 };
pub const IbPost = struct { no: i32, thread: i32, date: i64, name: []const u8, subj: []const u8, img: []const u8, img_type: []const u8, text: []const u8 };
pub const BookStat = struct { embed: bool = true, reads: i64 = 0, downloads: i64 = 0 };
pub const Profile = struct { hash: u64 = 0, kind: u8 = 0, w: u16 = 0, h: u16 = 0, pins: []const u8 = "" };
pub const Piece = struct { id: i32, author: i32, title: []const u8, genre: []const u8, year: []const u8, text: []const u8, chords: []const u8 = "", notes: []const u8 = "", uploader: i32 = 0, chordpro: bool = false, seq: i64 = 0 };
/// Запись /v/N: аудиокнига (book — /b/N) или исполнение стиха или песни
/// (piece — /p/N; text и notes — свои слова и ноты, если отличаются).
/// Основа необязательна: book и piece могут быть 0 — тогда запись
/// привязывают позже (к уже выложенной книге или стиху, или выкладывают их
/// от записи). author — автор произведения (/c/N или участник), пока основы нет.
/// reader — чтец или исполнитель /v/-N. Файл — voice/N.mp3.
pub const Recording = struct {
    id: i32,
    title: []const u8,
    reader: i32,
    audiobook: bool,
    book: i32 = 0,
    piece: i32 = 0,
    text: []const u8 = "",
    notes: []const u8 = "",
    uploader: i32 = 0,
    date: []const u8 = "",
    seconds: u32 = 0,
    bytes: u64 = 0,
    year: []const u8 = "",
    author: i32 = 0,
};
/// Чтец или исполнитель /v/-N; участником сайта быть не обязан. author — автор
/// произведений (/c/N или участник), если чтец — он сам: автор читает своё.
pub const Reader = struct { id: i32, name: []const u8, years: []const u8 = "", about: []const u8 = "", author: i32 = 0 };

pub const rights = struct {
    pub const forum: u8 = 1;
    pub const upload: u8 = 2;
    pub const comment: u8 = 4;
    pub const write: u8 = 8;
    pub const quote: u8 = 16;
    /// сотрудник: у него свой набор форматов загрузки книг (/panel)
    pub const staff: u8 = 32;
    pub const default: u8 = forum | comment | write | quote;
    pub const all: u8 = 63;
};

pub const Db = struct {
    l: *L.Ledger,
    s: *const snapshot.Snapshot,
    a: std.mem.Allocator,

    fn id32(v: i64) i32 {
        return std.math.cast(i32, v) orelse 0;
    }

    // ───────────── участники ─────────────

    pub fn user(d: Db, id: i32) ?User {
        const v = d.l.get(d.a, L.key(d.a, "U", .{id})) orelse return null;
        return .{ .id = id, .nick = L.field(v, 0), .joined = L.field(v, 1), .about = L.field(v, 2), .login = L.field(v, 3) };
    }

    pub fn putUser(d: Db, u: User) void {
        d.l.put(L.key(d.a, "U", .{u.id}), L.rec(d.a, .{ u.nick, u.joined, u.about, u.login }));
    }

    pub fn users(d: Db, negative: bool) []User {
        var list = std.ArrayList(User).init(d.a);
        var it = d.l.scan(d.a, if (negative) "U-" else "U+");
        while (it.next()) |e| {
            const id = id32(L.parseNum(e.key[1..]));
            list.append(.{ .id = id, .nick = L.field(e.val, 0), .joined = L.field(e.val, 1), .about = L.field(e.val, 2), .login = L.field(e.val, 3) }) catch break;
        }
        return list.items;
    }

    pub fn account(d: Db, login: []const u8) ?Account {
        const v = d.l.get(d.a, L.key(d.a, "A", .{login})) orelse return null;
        return .{ .login = login, .user = id32(L.fieldInt(v, 0)), .hash = L.field(v, 1), .rights = @intCast(L.fieldInt(v, 2) & rights.all), .blocked = L.fieldInt(v, 3) != 0 };
    }

    pub fn putAccount(d: Db, acc: Account) void {
        d.l.put(L.key(d.a, "A", .{acc.login}), L.rec(d.a, .{ acc.user, acc.hash, acc.rights, acc.blocked }));
    }

    /// Гость федерации: вошёл с другого сайта, логин «номер@сайт», пароля нет.
    pub fn external(login: []const u8) bool {
        return std.mem.indexOfScalar(u8, login, '@') != null;
    }

    pub fn accounts(d: Db) []Account {
        var list = std.ArrayList(Account).init(d.a);
        var it = d.l.scan(d.a, "A");
        while (it.next()) |e| list.append(.{ .login = e.key[1..], .user = id32(L.fieldInt(e.val, 0)), .hash = L.field(e.val, 1), .rights = @intCast(L.fieldInt(e.val, 2) & rights.all), .blocked = L.fieldInt(e.val, 3) != 0 }) catch break;
        return list.items;
    }

    // ───────────── люди и персонажи ─────────────

    pub fn person(d: Db, id: i32) ?Person {
        if (id > 0) {
            const p = d.s.person(id) orelse return null;
            return .{ .id = id, .name = d.s.str(p.name), .years = d.s.str(p.years), .about = d.s.str(p.about) };
        }
        const v = d.l.get(d.a, L.key(d.a, "X", .{id})) orelse return null;
        return .{ .id = id, .name = L.field(v, 0), .about = L.field(v, 1), .author = id32(L.fieldInt(v, 2)), .books = L.field(v, 3) };
    }

    pub fn putCharacter(d: Db, p: Person) void {
        d.l.put(L.key(d.a, "X", .{p.id}), L.rec(d.a, .{ p.name, p.about, p.author, p.books }));
    }

    pub fn characters(d: Db) []Person {
        var list = std.ArrayList(Person).init(d.a);
        var it = d.l.scan(d.a, "X");
        while (it.next()) |e| list.append(.{ .id = id32(L.parseNum(e.key[1..])), .name = L.field(e.val, 0), .about = L.field(e.val, 1), .author = id32(L.fieldInt(e.val, 2)), .books = L.field(e.val, 3) }) catch break;
        return list.items;
    }

    /// Имя участника, человека или персонажа; иначе «#N».
    pub fn name(d: Db, id: i32) []const u8 {
        if (d.user(id)) |u| return u.nick;
        if (d.person(id)) |p| return p.name;
        return std.fmt.allocPrint(d.a, "#{d}", .{id}) catch "#";
    }

    pub fn isUser(d: Db, id: i32) bool {
        return d.l.get(d.a, L.key(d.a, "U", .{id})) != null;
    }

    /// Привязан ли персонаж к книге: список пуст — ко всем книгам автора.
    pub fn charInBook(books: []const u8, book: i32) bool {
        if (books.len == 0) return true;
        var it = std.mem.splitScalar(u8, books, ',');
        while (it.next()) |x| if ((std.fmt.parseInt(i32, x, 10) catch continue) == book) return true;
        return false;
    }

    // ───────────── цитаты и закладки ─────────────

    fn quoteOf(e: L.Entry) Quote {
        return .{
            .id = id32(L.parseNum(e.key[1..])),
            .person = id32(L.fieldInt(e.val, 0)),
            .book = id32(L.fieldInt(e.val, 1)),
            .ch = @intCast(@max(0, L.fieldInt(e.val, 2))),
            .para = @intCast(@max(0, L.fieldInt(e.val, 3))),
            .by = id32(L.fieldInt(e.val, 4)),
            .date = L.field(e.val, 5),
            .text = L.field(e.val, 6),
            .src = blk: {
                const s = L.field(e.val, 7);
                break :blk if (s.len == 1 and (s[0] == 'p' or s[0] == 'd')) s[0] else 'b';
            },
        };
    }

    pub fn quotes(d: Db) []Quote {
        var list = std.ArrayList(Quote).init(d.a);
        var it = d.l.scan(d.a, "Q");
        while (it.next()) |e| list.append(quoteOf(e)) catch break;
        return list.items;
    }

    pub fn putQuote(d: Db, q: Quote) void {
        const src: []const u8 = switch (q.src) {
            'p' => "p",
            'd' => "d",
            else => "",
        };
        d.l.put(L.key(d.a, "Q", .{q.id}), L.rec(d.a, .{ q.person, q.book, q.ch, q.para, q.by, q.date, q.text, src }));
    }

    pub fn bookmarks(d: Db, uid: i32) []Bookmark {
        var list = std.ArrayList(Bookmark).init(d.a);
        var it = d.l.scan(d.a, L.key(d.a, "M", .{uid}));
        while (it.next()) |e| list.append(.{
            .id = id32(L.parseNum(e.key[12..])),
            .user = uid,
            .book = id32(L.fieldInt(e.val, 0)),
            .ch = @intCast(@max(0, L.fieldInt(e.val, 1))),
            .para = @intCast(@max(0, L.fieldInt(e.val, 2))),
            .date = L.field(e.val, 3),
            .note = L.field(e.val, 4),
            .text = L.field(e.val, 5),
        }) catch break;
        return list.items;
    }

    pub fn putBookmark(d: Db, m: Bookmark) void {
        d.l.put(L.key(d.a, "M", .{ m.user, m.id }), L.rec(d.a, .{ m.book, m.ch, m.para, m.date, m.note, m.text }));
    }

    pub fn delBookmark(d: Db, uid: i32, id: i32) void {
        d.l.del(L.key(d.a, "M", .{ uid, id }));
    }

    // ───────────── черновики ─────────────

    fn draftOf(id: i32, v: []const u8) Draft {
        return .{ .id = id, .title = L.field(v, 0), .author = id32(L.fieldInt(v, 1)), .created = L.field(v, 2), .moved = L.field(v, 3), .tags = L.field(v, 4), .text = L.field(v, 5), .seq = L.fieldInt(v, 6) };
    }

    pub fn draft(d: Db, id: i32) ?Draft {
        return draftOf(id, d.l.get(d.a, L.key(d.a, "D", .{id})) orelse return null);
    }

    pub fn drafts(d: Db, negative: bool) []Draft {
        var list = std.ArrayList(Draft).init(d.a);
        var it = d.l.scan(d.a, if (negative) "D-" else "D+");
        while (it.next()) |e| list.append(draftOf(id32(L.parseNum(e.key[1..])), e.val)) catch break;
        return list.items;
    }

    pub fn putDraft(d: Db, x: Draft) void {
        d.l.put(L.key(d.a, "D", .{x.id}), L.rec(d.a, .{ x.title, x.author, x.created, x.moved, x.tags, x.text, x.seq }));
    }

    // ───────────── комментарии к книгам ─────────────

    pub fn comments(d: Db, book: i32) []Comment {
        var list = std.ArrayList(Comment).init(d.a);
        var it = d.l.scan(d.a, L.key(d.a, "C", .{book}));
        while (it.next()) |e| list.append(.{ .id = id32(L.parseNum(e.key[12..])), .parent = id32(L.fieldInt(e.val, 0)), .author = id32(L.fieldInt(e.val, 1)), .date = L.field(e.val, 2), .text = L.field(e.val, 3) }) catch break;
        return list.items;
    }

    pub fn putComment(d: Db, book: i32, x: Comment) void {
        d.l.put(L.key(d.a, "C", .{ book, x.id }), L.rec(d.a, .{ x.parent, x.author, x.date, x.text }));
    }

    // ───────────── форум ─────────────

    pub fn forum(d: Db, id: i32) ?Forum {
        const v = d.l.get(d.a, L.key(d.a, "F", .{id})) orelse return null;
        return .{ .id = id, .title = L.field(v, 0), .about = L.field(v, 1) };
    }

    pub fn forums(d: Db) []Forum {
        var list = std.ArrayList(Forum).init(d.a);
        var it = d.l.scan(d.a, "F");
        while (it.next()) |e| list.append(.{ .id = id32(L.parseNum(e.key[1..])), .title = L.field(e.val, 0), .about = L.field(e.val, 1) }) catch break;
        return list.items;
    }

    pub fn topics(d: Db, forum_id: i32) []Topic {
        var list = std.ArrayList(Topic).init(d.a);
        var it = d.l.scan(d.a, L.key(d.a, "T", .{forum_id}));
        while (it.next()) |e| list.append(.{ .id = id32(L.parseNum(e.key[12..])), .forum = forum_id, .title = L.field(e.val, 0) }) catch break;
        return list.items;
    }

    pub fn topic(d: Db, forum_id: i32, id: i32) ?Topic {
        const v = d.l.get(d.a, L.key(d.a, "T", .{ forum_id, id })) orelse return null;
        return .{ .id = id, .forum = forum_id, .title = L.field(v, 0) };
    }

    fn postOf(topic_id: i32, e: L.Entry) Post {
        return .{ .id = id32(L.parseNum(e.key[12..])), .topic = topic_id, .author = id32(L.fieldInt(e.val, 0)), .date = L.field(e.val, 1), .forum = id32(L.fieldInt(e.val, 2)), .text = L.field(e.val, 3) };
    }

    pub fn posts(d: Db, topic_id: i32) []Post {
        var list = std.ArrayList(Post).init(d.a);
        var it = d.l.scan(d.a, L.key(d.a, "P", .{topic_id}));
        while (it.next()) |e| list.append(postOf(topic_id, e)) catch break;
        return list.items;
    }

    pub fn allPosts(d: Db) []Post {
        var list = std.ArrayList(Post).init(d.a);
        var it = d.l.scan(d.a, "P");
        while (it.next()) |e| list.append(postOf(id32(L.parseNum(e.key[1..12])), e)) catch break;
        return list.items;
    }

    pub fn putPost(d: Db, p: Post) void {
        d.l.put(L.key(d.a, "P", .{ p.topic, p.id }), L.rec(d.a, .{ p.author, p.date, p.forum, p.text }));
    }

    // ───────────── доски ─────────────

    pub fn board(d: Db, id: []const u8) ?Board {
        const v = d.l.get(d.a, L.key(d.a, "B", .{id})) orelse return null;
        return .{ .id = id, .title = L.field(v, 0), .ttl_min = L.fieldInt(v, 1) };
    }

    pub fn boards(d: Db) []Board {
        var list = std.ArrayList(Board).init(d.a);
        var it = d.l.scan(d.a, "B");
        while (it.next()) |e| list.append(.{ .id = e.key[1..], .title = L.field(e.val, 0), .ttl_min = L.fieldInt(e.val, 1) }) catch break;
        return list.items;
    }

    /// Посты доски по тредам (тред — посты с общим номером треда, первый — его начало).
    pub fn ibPosts(d: Db, board_id: []const u8) []IbPost {
        var list = std.ArrayList(IbPost).init(d.a);
        const prefix = L.key(d.a, "I", .{ board_id, ":" });
        var it = d.l.scan(d.a, prefix);
        while (it.next()) |e| {
            const rest = e.key[prefix.len..];
            if (rest.len < 22) continue;
            list.append(.{
                .thread = id32(L.parseNum(rest[0..11])),
                .no = id32(L.parseNum(rest[11..22])),
                .date = L.fieldInt(e.val, 0),
                .name = L.field(e.val, 1),
                .subj = L.field(e.val, 2),
                .img = L.field(e.val, 3),
                .img_type = L.field(e.val, 4),
                .text = L.field(e.val, 5),
            }) catch break;
        }
        return list.items;
    }

    pub fn putIbPost(d: Db, board_id: []const u8, p: IbPost) void {
        d.l.put(L.key(d.a, "I", .{ board_id, ":", p.thread, p.no }), L.rec(d.a, .{ p.date, p.name, p.subj, p.img, p.img_type, p.text }));
    }

    pub fn delIbPost(d: Db, board_id: []const u8, thread: i32, no: i32) void {
        d.l.del(L.key(d.a, "I", .{ board_id, ":", thread, no }));
    }

    // ───────────── книги: счётчики и флаги ─────────────

    pub fn bookStat(d: Db, id: i32) BookStat {
        const v = d.l.get(d.a, L.key(d.a, "b", .{id})) orelse return .{};
        return .{ .embed = L.fieldInt(v, 0) != 0, .reads = L.fieldInt(v, 1), .downloads = L.fieldInt(v, 2) };
    }

    pub fn putBookStat(d: Db, id: i32, st: BookStat, quiet: bool) void {
        const k = L.key(d.a, "b", .{id});
        const v = L.rec(d.a, .{ st.embed, st.reads, st.downloads });
        if (quiet) d.l.putQuiet(k, v) else d.l.put(k, v);
    }

    // ───────────── стихи ─────────────

    pub fn piece(d: Db, id: i32) ?Piece {
        const p = d.s.piece(id) orelse return null;
        return d.pieceOf(p);
    }

    pub fn pieceOf(d: Db, p: *const snapshot.Piece) Piece {
        return .{ .id = p.id, .author = p.author, .title = d.s.str(p.title), .genre = d.s.str(p.genre), .year = d.s.str(p.year), .text = d.s.str(p.text), .chords = d.s.str(p.chords), .notes = d.s.str(p.notes), .uploader = p.uploader, .chordpro = p.flags & snapshot.piece_chordpro != 0 };
    }

    /// Стих или песня, как они лежат в хранилище (свежее снимка: правка видна сразу).
    pub fn pieceRec(d: Db, id: i32) ?Piece {
        const v = d.l.get(d.a, L.key(d.a, "p", .{id})) orelse return null;
        const seq_s = L.field(v, 7);
        return .{ .id = id, .title = L.field(v, 0), .author = id32(L.fieldInt(v, 1)), .genre = L.field(v, 2), .year = L.field(v, 3), .text = L.field(v, 4), .chords = L.field(v, 5), .notes = L.field(v, 6), .seq = if (seq_s.len > 0) std.fmt.parseInt(i64, seq_s, 10) catch 0 else 0, .uploader = id32(L.fieldInt(v, 8)), .chordpro = std.mem.eql(u8, L.field(v, 9), "chordpro") };
    }

    pub fn putPiece(d: Db, p: Piece) void {
        var sb: [24]u8 = undefined;
        const seq = if (p.seq != 0) std.fmt.bufPrint(&sb, "{d}", .{p.seq}) catch "" else "";
        d.l.put(L.key(d.a, "p", .{p.id}), L.rec(d.a, .{ p.title, p.author, p.genre, p.year, p.text, p.chords, p.notes, seq, p.uploader, if (p.chordpro) "chordpro" else "" }));
    }

    pub fn delPiece(d: Db, id: i32) void {
        d.l.del(L.key(d.a, "p", .{id}));
    }

    // ───────────── профили: фото и закреплённые обсуждения ─────────────

    /// Ключ Y<номер>: фото (отпечаток в img/b, вид, размер) и закреплённые («f1,bzz»).
    pub fn profile(d: Db, id: i32) Profile {
        const v = d.l.get(d.a, L.key(d.a, "Y", .{id})) orelse return .{};
        return .{
            .hash = std.fmt.parseInt(u64, L.field(v, 0), 16) catch 0,
            .kind = std.math.cast(u8, L.fieldInt(v, 1)) orelse 0,
            .w = std.math.cast(u16, L.fieldInt(v, 2)) orelse 0,
            .h = std.math.cast(u16, L.fieldInt(v, 3)) orelse 0,
            .pins = L.field(v, 4),
        };
    }

    pub fn putProfile(d: Db, id: i32, p: Profile) void {
        if (p.hash == 0 and p.pins.len == 0) return d.l.del(L.key(d.a, "Y", .{id}));
        var hb: [16]u8 = undefined;
        d.l.put(L.key(d.a, "Y", .{id}), L.rec(d.a, .{ std.fmt.bufPrint(&hb, "{x:0>16}", .{p.hash}) catch "", p.kind, p.w, p.h, p.pins }));
    }

    /// Фото всех профилей — уборка хранилища картинок их не трогает.
    pub fn profilePhotos(d: Db) []snapshot.Image {
        var out = std.ArrayList(snapshot.Image).init(d.a);
        var it = d.l.scan(d.a, "Y");
        while (it.next()) |e| {
            const hash = std.fmt.parseInt(u64, L.field(e.val, 0), 16) catch continue;
            if (hash == 0) continue;
            out.append(.{ .hash = hash, .w = 0, .h = 0, .kind = std.math.cast(u8, L.fieldInt(e.val, 1)) orelse 0 }) catch break;
        }
        return out.items;
    }

    // ───────────── привязка участника к авторам ─────────────

    /// Люди каталога (/c/N, N > 0), которыми является участник: ключ w<участник> — номера через запятую.
    pub fn authorsOf(d: Db, uid: i32) []i32 {
        var out = std.ArrayList(i32).init(d.a);
        const v = d.l.get(d.a, L.key(d.a, "w", .{uid})) orelse return out.items;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |x| out.append(std.fmt.parseInt(i32, x, 10) catch continue) catch break;
        return out.items;
    }

    pub fn setAuthorsOf(d: Db, uid: i32, ids: []const i32) void {
        if (ids.len == 0) return d.l.del(L.key(d.a, "w", .{uid}));
        var s = std.ArrayList(u8).init(d.a);
        for (ids, 0..) |x, i| s.writer().print("{s}{d}", .{ if (i > 0) "," else "", x }) catch return;
        d.l.put(L.key(d.a, "w", .{uid}), s.items);
    }

    /// Участники, привязанные к человеку каталога.
    pub fn usersOfAuthor(d: Db, pid: i32) []i32 {
        var out = std.ArrayList(i32).init(d.a);
        var it = d.l.scan(d.a, "w");
        while (it.next()) |e| {
            const uid = id32(L.parseNum(e.key[1..]));
            var p = std.mem.splitScalar(u8, e.val, ',');
            while (p.next()) |x| if ((std.fmt.parseInt(i32, x, 10) catch continue) == pid) {
                out.append(uid) catch break;
                break;
            };
        }
        return out.items;
    }

    /// Человек каталога по имени: есть — его номер, нет — заводится (с годами и описанием).
    pub fn personByName(d: Db, nm: []const u8, years: []const u8, about: []const u8) i32 {
        const low = d.a.dupe(u8, nm) catch return 0;
        for (low) |*ch| ch.* = cp1251.lower(ch.*);
        const k = L.key(d.a, "n", .{low});
        if (d.l.get(d.a, k)) |v| {
            const old = std.fmt.parseInt(i32, v, 10) catch 0;
            if (old > 0) return old;
        }
        var id: i32 = undefined;
        while (true) {
            id = d.nextId("person", 5, 1);
            if (!d.isUser(id) and d.s.person(id) == null) break;
        }
        var buf: [16]u8 = undefined;
        d.l.put(k, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        d.l.put(L.key(d.a, "H", .{id}), L.rec(d.a, .{ nm, years, about }));
        return id;
    }

    // ───────────── записи /v: аудиокниги, исполнения, чтецы ─────────────

    pub fn recording(d: Db, id: i32) ?Recording {
        if (id <= 0) return null;
        const v = d.l.get(d.a, L.key(d.a, "V", .{id})) orelse return null;
        return recOf(id, v);
    }

    fn recOf(id: i32, v: []const u8) Recording {
        return .{
            .id = id,
            .title = L.field(v, 0),
            .reader = id32(L.fieldInt(v, 1)),
            .book = id32(L.fieldInt(v, 2)),
            .piece = id32(L.fieldInt(v, 3)),
            .text = L.field(v, 4),
            .notes = L.field(v, 5),
            .uploader = id32(L.fieldInt(v, 6)),
            .date = L.field(v, 7),
            .seconds = std.math.cast(u32, L.fieldInt(v, 8)) orelse 0,
            .bytes = std.math.cast(u64, L.fieldInt(v, 9)) orelse 0,
            .year = L.field(v, 10),
            .audiobook = std.mem.eql(u8, L.field(v, 11), "book"),
            .author = id32(L.fieldInt(v, 12)),
        };
    }

    pub fn putRecording(d: Db, r: Recording) void {
        d.l.put(L.key(d.a, "V", .{r.id}), L.rec(d.a, .{ r.title, r.reader, r.book, r.piece, r.text, r.notes, r.uploader, r.date, r.seconds, @as(i64, @intCast(r.bytes)), r.year, if (r.audiobook) "book" else "perf", r.author }));
    }

    pub fn delRecording(d: Db, id: i32) void {
        d.l.del(L.key(d.a, "V", .{id}));
    }

    /// Все записи по возрастанию номера.
    pub fn recordings(d: Db) []Recording {
        var list = std.ArrayList(Recording).init(d.a);
        var it = d.l.scan(d.a, "V+");
        while (it.next()) |e| list.append(recOf(id32(L.parseNum(e.key[1..])), e.val)) catch break;
        std.mem.sort(Recording, list.items, {}, struct {
            fn lt(_: void, x: Recording, y: Recording) bool {
                return x.id < y.id;
            }
        }.lt);
        return list.items;
    }

    pub fn reader(d: Db, id: i32) ?Reader {
        if (id >= 0) return null;
        const v = d.l.get(d.a, L.key(d.a, "V", .{id})) orelse return null;
        return .{ .id = id, .name = L.field(v, 0), .years = L.field(v, 1), .about = L.field(v, 2), .author = id32(L.fieldInt(v, 3)) };
    }

    pub fn putReader(d: Db, r: Reader) void {
        d.l.put(L.key(d.a, "V", .{r.id}), L.rec(d.a, .{ r.name, r.years, r.about, r.author }));
    }

    /// Чтец, который и есть автор `aid`: есть — его номер, нет — заводится под именем автора.
    pub fn readerOfAuthor(d: Db, aid: i32) i32 {
        for (d.readers()) |r| if (r.author == aid) return r.id;
        const id = d.readerByName(d.name(aid), if (d.person(aid)) |p| p.years else "");
        if (id == 0) return 0;
        var r = d.reader(id) orelse return 0;
        if (r.author == 0) {
            r.author = aid;
            d.putReader(r);
        }
        return id;
    }

    /// Источник произведения: адрес или название (mrakopedia, arxiv, habr…). kind — b, p, v, d.
    pub fn source(d: Db, kind: u8, id: i32) []const u8 {
        return d.l.get(d.a, L.key(d.a, "O", .{ &[1]u8{kind}, id })) orelse "";
    }

    pub fn setSource(d: Db, kind: u8, id: i32, v: []const u8) void {
        const k = L.key(d.a, "O", .{ &[1]u8{kind}, id });
        if (v.len == 0) d.l.del(k) else d.l.put(k, v);
    }

    pub fn readers(d: Db) []Reader {
        var list = std.ArrayList(Reader).init(d.a);
        var it = d.l.scan(d.a, "V-");
        while (it.next()) |e| list.append(.{ .id = id32(L.parseNum(e.key[1..])), .name = L.field(e.val, 0), .years = L.field(e.val, 1), .about = L.field(e.val, 2), .author = id32(L.fieldInt(e.val, 3)) }) catch break;
        std.mem.sort(Reader, list.items, {}, struct {
            fn lt(_: void, x: Reader, y: Reader) bool {
                return x.id > y.id;
            }
        }.lt);
        return list.items;
    }

    /// Чтец по имени: есть — его номер (< 0), нет — заводится. Ключ r<имя строчными>.
    pub fn readerByName(d: Db, nm: []const u8, years: []const u8) i32 {
        const low = d.a.dupe(u8, nm) catch return 0;
        for (low) |*ch| ch.* = cp1251.lower(ch.*);
        const k = L.key(d.a, "r", .{low});
        if (d.l.get(d.a, k)) |v| {
            const old = std.fmt.parseInt(i32, v, 10) catch 0;
            if (old < 0 and d.reader(old) != null) return old;
        }
        var id: i32 = undefined;
        while (true) {
            id = d.nextId("reader", -1, -1);
            if (d.reader(id) == null) break;
        }
        var buf: [16]u8 = undefined;
        d.l.put(k, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable);
        d.putReader(.{ .id = id, .name = nm, .years = years });
        return id;
    }

    /// Чтецы, которыми является участник: ключ v<участник> — номера через запятую.
    pub fn readersOf(d: Db, uid: i32) []i32 {
        var out = std.ArrayList(i32).init(d.a);
        const v = d.l.get(d.a, L.key(d.a, "v", .{uid})) orelse return out.items;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |x| out.append(std.fmt.parseInt(i32, x, 10) catch continue) catch break;
        return out.items;
    }

    pub fn setReadersOf(d: Db, uid: i32, ids: []const i32) void {
        if (ids.len == 0) return d.l.del(L.key(d.a, "v", .{uid}));
        var s = std.ArrayList(u8).init(d.a);
        for (ids, 0..) |x, i| s.writer().print("{s}{d}", .{ if (i > 0) "," else "", x }) catch return;
        d.l.put(L.key(d.a, "v", .{uid}), s.items);
    }

    /// Участники, привязанные к чтецу.
    pub fn usersOfReader(d: Db, rid: i32) []i32 {
        var out = std.ArrayList(i32).init(d.a);
        var it = d.l.scan(d.a, "v");
        while (it.next()) |e| {
            const uid = id32(L.parseNum(e.key[1..]));
            var p = std.mem.splitScalar(u8, e.val, ',');
            while (p.next()) |x| if ((std.fmt.parseInt(i32, x, 10) catch continue) == rid) {
                out.append(uid) catch break;
                break;
            };
        }
        return out.items;
    }

    // ───────────── настройки и счётчики ─────────────

    pub fn setting(d: Db, comptime k: []const u8) ?[]const u8 {
        return d.l.get(d.a, "K" ++ k);
    }

    pub fn setSetting(d: Db, comptime k: []const u8, v: []const u8) void {
        d.l.put("K" ++ k, v);
    }

    /// Следующий номер счётчика `k`: начинается с `first`, шаг `step` (−1 для отрицательных).
    pub fn nextId(d: Db, comptime k: []const u8, first: i32, step: i32) i32 {
        const cur = if (d.l.get(d.a, "N" ++ k)) |v| id32(std.fmt.parseInt(i64, v, 10) catch first) else first;
        var buf: [16]u8 = undefined;
        d.l.put("N" ++ k, std.fmt.bufPrint(&buf, "{d}", .{cur + step}) catch unreachable);
        return cur;
    }
};
