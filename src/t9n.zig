//! Перевод интерфейса при компиляции (`zig build -Dlang=ru|en`).
//!
//! Язык исходников — русский: строка в коде и есть ключ. Каталог языка
//! (`src/t9n/ЯЗЫК.t9n`) сборка превращает в модуль `t9n_table` — пары
//! «русская строка — перевод». `tr` подставляет перевод там, где строка
//! исходника становится байтами страницы: в `cp.lit`, `cp.text`, `W.f` и,
//! через них, в шаблонах. Чего в каталоге нет, остаётся русским.
//!
//! Для русской сборки таблица пуста, и `tr` возвращает свой аргумент: цена
//! перевода — ноль и при компиляции, и в работе. В готовом бинарнике языка
//! нет вовсе: там только уже выбранные строки.

const std = @import("std");
const table = @import("t9n_table");

pub const active = table.pairs.len > 0;

const map = blk: {
    @setEvalBranchQuota(table.pairs.len * 4000 + 1000);
    break :blk std.StaticStringMap([]const u8).initComptime(table.pairs);
};

fn hasNonAscii(comptime s: []const u8) bool {
    @setEvalBranchQuota(s.len * 4 + 1000);
    for (s) |c| if (c >= 0x80) return true;
    return false;
}

/// Перевод строки исходника. Строки из одной латиницы — адреса, имена полей,
/// разметка — не ищутся: это не текст для человека.
pub fn tr(comptime s: []const u8) []const u8 {
    if (!active) return s;
    return comptime if (hasNonAscii(s)) (map.get(s) orelse s) else s;
}

test "без каталога строка остаётся собой" {
    if (active) return error.SkipZigTest;
    try std.testing.expectEqualStrings("Книги", tr("Книги"));
}
