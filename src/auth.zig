//! Учётные записи, сеансы, права, функции сайта, встроенный администратор /u/0.
//! Пароли — Argon2id; сеанс — случайный cookie `sid`, в хранилище лежит его хеш.

const std = @import("std");
const net = @import("net/net.zig");
const builtin = @import("builtin");
const cp = @import("cp1251.zig");
const L = @import("ledger.zig");
const dbm = @import("db.zig");
const sys = @import("sys.zig");

pub const Feature = enum(u4) { poems, books, quotes, drafts, forum, boards, upload, comments, embed, badges, signup, downloads };
pub const all_features: u16 = 0x0FFF;

pub fn bit(f: Feature) u16 {
    return @as(u16, 1) << @intFromEnum(f);
}

pub const FeatureName = struct { f: Feature, key: []const u8, label: []const u8 };
/// В порядке панели макета.
pub const feature_names = [_]FeatureName{
    .{ .f = .poems, .key = "poems", .label = cp.lit("Стихи и песни (/p)") },
    .{ .f = .books, .key = "books", .label = cp.lit("Книги (/b, /q)") },
    .{ .f = .quotes, .key = "quotes", .label = cp.lit("Цитаты (/c)") },
    .{ .f = .drafts, .key = "drafts", .label = cp.lit("Черновики и статьи (/d)") },
    .{ .f = .forum, .key = "forum", .label = cp.lit("Форумы (/f/N)") },
    .{ .f = .boards, .key = "boards", .label = cp.lit("Анонимные доски (/f/str)") },
    .{ .f = .upload, .key = "upload", .label = cp.lit("Публичное выкладывание книг") },
    .{ .f = .comments, .key = "comments", .label = cp.lit("Комментарии к книгам") },
    .{ .f = .downloads, .key = "downloads", .label = cp.lit("Скачивание книг (txt, fb2, epub)") },
    .{ .f = .embed, .key = "embed", .label = cp.lit("Встраивание через iframe (/e/...)") },
    .{ .f = .badges, .key = "badges", .label = cp.lit("Бейджи и информеры (/x/...)") },
    .{ .f = .signup, .key = "signup", .label = cp.lit("Регистрация новых участников") },
};

pub const RightName = struct { bit: u8, key: []const u8, label: []const u8 };
pub const right_names = [_]RightName{
    .{ .bit = dbm.rights.forum, .key = "forum", .label = cp.lit("участвовать на форуме") },
    .{ .bit = dbm.rights.upload, .key = "upload", .label = cp.lit("выкладывать книги (/b/upload)") },
    .{ .bit = dbm.rights.comment, .key = "comment", .label = cp.lit("комментировать книги") },
    .{ .bit = dbm.rights.write, .key = "write", .label = cp.lit("черновики, стихи, статьи") },
    .{ .bit = dbm.rights.quote, .key = "quote", .label = cp.lit("цитаты и персонажи") },
    .{ .bit = dbm.rights.staff, .key = "staff", .label = cp.lit("сотрудник: управляет сайтом наравне с /u/0 (кроме прав сотрудников)") },
};

/// Какие форматы книг вправе выкладывать сотрудники и прочие участники
/// (бит — номер `import.Kind`). Администратор /u/0 выкладывает любые.
pub const Formats = struct {
    staff: u8 = all,
    users: u8 = all,
    pub const all: u8 = 31;
};

pub fn rightLabel(b: u8) []const u8 {
    for (right_names) |r| if (r.bit == b) return r.label;
    return "";
}

// ───────────── пароли ─────────────

const params: std.crypto.pwhash.argon2.Params = if (builtin.mode == .Debug) .{ .t = 1, .m = 64, .p = 1 } else .{ .t = 2, .m = 8 * 1024, .p = 1 };

/// Хеш `$argon2id$…`; память — из `a`. Пустая строка — не удалось.
pub fn hashPassword(a: std.mem.Allocator, pass: []const u8) []const u8 {
    const buf = a.alloc(u8, 160) catch return "";
    return std.crypto.pwhash.argon2.strHash(pass, .{ .allocator = std.heap.page_allocator, .params = params, .mode = .argon2id }, buf) catch "";
}

pub fn verifyPassword(hash: []const u8, pass: []const u8) bool {
    if (hash.len == 0) return false;
    std.crypto.pwhash.argon2.strVerify(hash, pass, .{ .allocator = std.heap.page_allocator }) catch return false;
    return true;
}

// ───────────── встроенный администратор ─────────────

pub const Admin = struct {
    login: []const u8 = "admin",
    /// пусто — пароль не задан, войти нельзя
    hash: []const u8 = "",
};

/// Строка PHC для -phc: только argon2id, и она должна разбираться.
pub fn phcOk(phc: []const u8) bool {
    if (!std.mem.startsWith(u8, phc, "$argon2id$") or phc.len > 200) return false;
    // проверка пустым паролем: «не тот пароль» — строка годная, иная ошибка — нет
    std.crypto.pwhash.argon2.strVerify(phc, "", .{ .allocator = std.heap.page_allocator }) catch |err| return err == error.PasswordVerificationFailed;
    return true;
}

// ───────────── сеансы ─────────────

pub const Session = struct { key: []const u8, login: []const u8, hid: []const u8, created: i64, seen: i64, ip: []const u8, ua: []const u8 };

fn hex(a: std.mem.Allocator, bytes: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(bytes)}) catch "";
}

pub fn randomToken(buf: *[32]u8) void {
    var raw: [16]u8 = undefined;
    sys.random(&raw);
    _ = std.fmt.bufPrint(buf, "{s}", .{std.fmt.fmtSliceHexLower(&raw)}) catch unreachable;
}

pub fn validToken(s: []const u8) bool {
    if (s.len != 32) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Ключ записи сеанса: в хранилище лежит не сам cookie, а его хеш.
pub fn sessionKey(a: std.mem.Allocator, sid: []const u8) []const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sid, &h, .{});
    return std.fmt.allocPrint(a, "S{s}", .{std.fmt.fmtSliceHexLower(h[0..16])}) catch "";
}

fn sessionOf(key: []const u8, v: []const u8) Session {
    return .{ .key = key, .login = L.field(v, 0), .hid = L.field(v, 1), .created = L.fieldInt(v, 2), .seen = L.fieldInt(v, 3), .ip = L.field(v, 4), .ua = L.field(v, 5) };
}

pub const session_ttl_s = 30 * 24 * 3600;
/// Гость федерации: токен обнуляется после 45 минут бездействия (и с закрытием
/// браузера: у cookie сеанса нет срока).
pub const external_ttl_s = 45 * 60;

pub fn ttlOf(login: []const u8) i64 {
    return if (dbm.Db.external(login)) external_ttl_s else session_ttl_s;
}

pub fn session(d: dbm.Db, sid: []const u8, now: i64) ?Session {
    if (!validToken(sid)) return null;
    const key = sessionKey(d.a, sid);
    const v = d.l.get(d.a, key) orelse return null;
    var s = sessionOf(key, v);
    if (now - s.seen > ttlOf(s.login)) {
        d.l.del(key);
        return null;
    }
    if (now - s.seen >= 60) {
        s.seen = now;
        d.l.putQuiet(key, L.rec(d.a, .{ s.login, s.hid, s.created, s.seen, s.ip, s.ua }));
    }
    return s;
}

/// Заводит сеанс; возвращает значение cookie.
pub fn startSession(d: dbm.Db, login: []const u8, ua: []const u8, ip: net.Ip, now: i64) []const u8 {
    const sid = d.a.alloc(u8, 32) catch return "";
    randomToken(sid[0..32]);
    var hid: [32]u8 = undefined;
    randomToken(&hid);
    var ua_buf: [120]u8 = undefined;
    const n = @min(ua.len, ua_buf.len);
    for (ua[0..n], ua_buf[0..n]) |c, *o| o.* = if (c < 0x20 or c == 0x7F) ' ' else c;
    var ip_buf: [40]u8 = undefined;
    const ip_s = net.ipText(&ip_buf, ip);
    d.l.putQuiet(sessionKey(d.a, sid), L.rec(d.a, .{ login, hid[0..8], now, now, ip_s, if (n > 0) ua_buf[0..n] else "?" }));
    return sid;
}

pub fn sessionsOf(d: dbm.Db, login: []const u8) []Session {
    var list = std.ArrayList(Session).init(d.a);
    var it = d.l.scan(d.a, "S");
    while (it.next()) |e| {
        if (std.mem.eql(u8, L.field(e.val, 0), login)) list.append(sessionOf(e.key, e.val)) catch break;
    }
    return list.items;
}

/// Завершает сеансы `login`: один по открытому имени `hid` или все («*»).
/// true — среди них был текущий.
pub fn endSessions(d: dbm.Db, login: []const u8, hid: []const u8, current_key: []const u8) bool {
    var cur = false;
    const all = std.mem.eql(u8, hid, "*");
    const list = sessionsOf(d, login);
    var keys = std.ArrayList([]const u8).init(d.a);
    for (list) |s| {
        if (all or std.mem.eql(u8, s.hid, hid)) {
            keys.append(d.a.dupe(u8, s.key) catch continue) catch break;
            if (std.mem.eql(u8, s.key, current_key)) cur = true;
        }
    }
    for (keys.items) |k| d.l.del(k);
    return cur;
}

test "гость федерации: токен гаснет через 45 минут бездействия" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ledger = try L.Ledger.open(std.testing.allocator, tmp.dir, .journal);
    defer ledger.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const d = dbm.Db{ .l = &ledger, .s = undefined, .a = arena.allocator() };
    const t0: i64 = 1_800_000_000;
    const min = 60;
    const guest = startSession(d, "1002@a.example", "ua", net.loopback, t0);
    const local = startSession(d, "reader", "ua", net.loopback, t0);
    // каждое обращение продлевает токен
    try std.testing.expect(session(d, guest, t0 + 44 * min) != null);
    try std.testing.expect(session(d, guest, t0 + 88 * min) != null);
    try std.testing.expect(session(d, guest, t0 + 133 * min) != null); // ровно 45 минут — ещё жив
    // 45 минут и секунда без обращений — токена нет, и запись о нём стёрта
    try std.testing.expect(session(d, guest, t0 + 178 * min + 1) == null);
    try std.testing.expect(session(d, guest, t0 + 178 * min + 2) == null);
    try std.testing.expectEqual(@as(usize, 0), sessionsOf(d, "1002@a.example").len);
    // сеанс по паролю живёт 30 суток
    try std.testing.expect(session(d, local, t0 + 29 * 24 * 3600) != null);
}

