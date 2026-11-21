//! Разделы сайта и флаги запуска -M, -R, -G, -N (DIGITALLIBRARY_RU_RND.md).
//!
//!   p  стихи и песни      b  книги и закладки     d  черновики и статьи
//!   f  форумы и доски     q  цитаты, люди и персонажи
//!   v  аудиокниги, чтецы и исполнители (только в сборке с -Dvoice, по умолчанию)
//!
//!   -M  пишут только модераторы (право «сотрудник» и /u/0); остальным — чтение
//!   -R  только чтение для всех
//!   -G  открыто гостям; задан хоть раз — гость видит только перечисленное
//!   -N  раздела нет вовсе
//!
//! Флаги — потолок: панель может только сузить. Книги при -Nb, если цитаты
//! включены, не исчезают, а прячутся: открываются на чтение по ссылке из цитаты.

const std = @import("std");
const t9n = @import("t9n.zig");
const has_voice = @import("config").voice;

pub const Sec = enum(u3) { p, b, d, f, q, v };
pub const Set = u6;
/// Буквы флагов; v — только в сборке с разделом /v.
pub const letters = if (has_voice) "pbdfqv" else "pbdfq";
/// Все разделы сборки.
pub const all: Set = if (has_voice) 0b111111 else 0b011111;

pub fn bit(s: Sec) Set {
    return @as(Set, 1) << @intFromEnum(s);
}

pub const Rules = struct {
    mod: Set = 0,
    ro: Set = 0,
    guest: Set = 0,
    guest_set: bool = false,
    off: Set = 0,

    pub fn has(set: Set, s: Sec) bool {
        return set & bit(s) != 0;
    }

    /// Книги выключены, а цитаты нет: книги — только источник цитат.
    pub fn booksHidden(r: Rules) bool {
        return has(r.off, .b) and !has(r.off, .q);
    }

    /// Раздел есть хоть в каком-то виде (скрытые книги — есть).
    pub fn exists(r: Rules, s: Sec) bool {
        return !has(r.off, s) or (s == .b and r.booksHidden());
    }

    /// Открыт ли раздел гостю. Скрытые книги открыты гостю вместе с цитатами.
    pub fn guestOk(r: Rules, s: Sec) bool {
        if (!r.guest_set) return true;
        if (has(r.guest, s)) return true;
        return s == .b and r.booksHidden() and has(r.guest, .q);
    }

    /// Писать в раздел: есть, не только чтение, не скрыт; при -M — только модератор.
    pub fn writable(r: Rules, s: Sec, moderator: bool) bool {
        if (has(r.off, s) or has(r.ro, s)) return false;
        return !has(r.mod, s) or moderator;
    }

    /// Ровно один включённый раздел — у сайта одна тема (архетипы B, C, D, E).
    pub fn count(r: Rules) u3 {
        return @intCast(@popCount(~r.off & all));
    }
};

/// Буквы флага → набор. Ошибка — строка для сообщения.
pub fn parseSet(s: []const u8, msg: *[]const u8) ?Set {
    var set: Set = 0;
    if (s.len == 0) {
        msg.* = if (has_voice) t9n.tr("после -M, -R, -G и -N нужны буквы разделов: p (стихи), b (книги), d (черновики), f (форумы), q (цитаты), v (записи)") else t9n.tr("после -M, -R, -G и -N нужны буквы разделов: p (стихи), b (книги), d (черновики), f (форумы), q (цитаты)");
        return null;
    }
    for (s) |ch| {
        const i = std.mem.indexOfScalar(u8, letters, ch) orelse {
            msg.* = if (has_voice) t9n.tr("неизвестный раздел: бывают p (стихи), b (книги), d (черновики), f (форумы), q (цитаты), v (записи)") else t9n.tr("неизвестный раздел: бывают p (стихи), b (книги), d (черновики), f (форумы), q (цитаты)");
            return null;
        };
        const b = @as(Set, 1) << @intCast(i);
        if (set & b != 0) {
            msg.* = t9n.tr("буква раздела повторяется в одном флаге (-M, -R, -G или -N)");
            return null;
        }
        set |= b;
    }
    return set;
}

/// Проверка сочетания флагов: выключенное (-N) нельзя упоминать в -M, -R, -G.
pub fn check(r: Rules, msg: *[]const u8) bool {
    if (r.off & (r.mod | r.ro | r.guest) != 0) {
        msg.* = t9n.tr("раздел из -N выключен совсем: его нельзя упоминать в -M, -R или -G");
        return false;
    }
    if (r.off == all) {
        msg.* = t9n.tr("-N выключает все разделы: сайту нечего показать");
        return false;
    }
    return true;
}

test "разделы: разбор и сочетания" {
    var msg: []const u8 = "";
    try std.testing.expectEqual(@as(?Set, bit(.b) | bit(.f)), parseSet("bf", &msg));
    try std.testing.expect(parseSet("bb", &msg) == null);
    try std.testing.expect(parseSet("x", &msg) == null);
    try std.testing.expect(!check(.{ .off = bit(.b), .mod = bit(.b) }, &msg));
    const quotes_only = Rules{ .off = bit(.p) | bit(.b) | bit(.d) | bit(.f) };
    try std.testing.expect(quotes_only.booksHidden());
    try std.testing.expect(quotes_only.exists(.b));
    try std.testing.expect(!quotes_only.writable(.b, true));
    const r = Rules{ .mod = bit(.b), .ro = bit(.f), .guest = bit(.p), .guest_set = true };
    try std.testing.expect(r.writable(.b, true) and !r.writable(.b, false));
    try std.testing.expect(!r.writable(.f, true));
    try std.testing.expect(r.guestOk(.p) and !r.guestOk(.b));
}
