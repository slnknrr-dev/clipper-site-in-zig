//! Записи сайта (участники, сеансы, права, функции, комментарии, форум,
//! доски, черновики, цитаты, закладки, настройки) — упорядоченное хранилище
//! «ключ → значение» с одним интерфейсом над двумя хранилищами:
//!
//!   journal  файл строк, всё состояние в памяти (по умолчанию)
//!   btree    B+ дерево copy-on-write, запись читается по запросу (-btree)
//!
//! Оба принимают одни и те же записи; тест гоняет одну историю через оба.
//! Значение — поля через 0x1F (в тексте форм управляющих символов нет).

const std = @import("std");
const journal = @import("journal.zig");
const btree = @import("btree.zig");

pub const Kind = enum { journal, btree };
pub const Entry = struct { key: []const u8, val: []const u8 };
pub const sep: u8 = 0x1F;

pub const Ledger = struct {
    backend: union(Kind) { journal: journal.Journal, btree: btree.Tree },
    /// Растёт при каждом изменении, заметном на страницах (сброс кэша страниц).
    changes: u64 = 1,
    dirty: bool = false,
    failed: bool = false,
    /// Применены записи другого процесса; приложение сбрасывает флаг, когда
    /// обновит то, что держит в памяти (вход администратора, снимок).
    foreign: bool = false,

    pub fn open(gpa: std.mem.Allocator, dir: std.fs.Dir, kind: Kind) !Ledger {
        return switch (kind) {
            .journal => .{ .backend = .{ .journal = try journal.Journal.open(gpa, dir) } },
            .btree => blk: {
                btree.compactIfNeeded(gpa, dir) catch {};
                break :blk .{ .backend = .{ .btree = try btree.Tree.open(gpa, dir) } };
            },
        };
    }

    pub fn close(l: *Ledger) void {
        switch (l.backend) {
            inline else => |*b| b.close(),
        }
    }

    /// Значение — копия в `a`: его не испортит последующая запись того же ключа.
    pub fn get(l: *Ledger, a: std.mem.Allocator, k: []const u8) ?[]const u8 {
        return switch (l.backend) {
            .journal => |*j| if (j.get(k)) |v| (a.dupe(u8, v) catch null) else null,
            .btree => |*t| t.get(a, k) catch null,
        };
    }

    fn write(l: *Ledger, k: []const u8, val: ?[]const u8) void {
        const r = switch (l.backend) {
            inline else => |*b| if (val) |v| b.put(k, v) else b.del(k),
        };
        r catch {
            l.failed = true;
        };
        l.dirty = true;
    }

    pub fn put(l: *Ledger, k: []const u8, val: []const u8) void {
        l.write(k, val);
        l.changes += 1;
    }

    pub fn del(l: *Ledger, k: []const u8) void {
        l.write(k, null);
        l.changes += 1;
    }

    /// Запись, которая не меняет страниц гостей (счётчики, время сеанса).
    pub fn putQuiet(l: *Ledger, k: []const u8, val: []const u8) void {
        l.write(k, val);
    }

    /// Доводит изменения до диска. Ошибка — запись могла не сохраниться.
    pub fn flush(l: *Ledger) !void {
        if (!l.dirty) return;
        l.dirty = false;
        const failed = l.failed;
        l.failed = false;
        switch (l.backend) {
            .journal => |*j| if (try j.flush()) {
                l.changes += 1;
                l.foreign = true;
            },
            .btree => |*t| try t.commit(),
        }
        if (failed) return error.WriteFailed;
    }

    /// Подхватывает записи другого процесса (команда `clipper …` рядом с сервером).
    pub fn refresh(l: *Ledger) void {
        if (l.dirty) return;
        const changed = switch (l.backend) {
            .journal => |*j| j.catchUp() catch false,
            .btree => |*t| t.refresh() catch false,
        };
        if (changed) {
            l.changes += 1;
            l.foreign = true;
        }
    }

    /// Блокировка хранилища на весь запрос записи (несколько воркеров): чужие
    /// записи дочитаны, и до release никто другой ничего не допишет. Без неё
    /// два процесса прочли бы одно состояние и выдали один и тот же новый номер.
    pub fn hold(l: *Ledger) !void {
        const changed = switch (l.backend) {
            inline else => |*b| try b.hold(),
        };
        if (changed) {
            l.changes += 1;
            l.foreign = true;
        }
    }

    pub fn release(l: *Ledger) void {
        if (l.dirty) l.flush() catch {}; // записанное после последнего flush — тоже под блокировкой
        switch (l.backend) {
            inline else => |*b| b.release(),
        }
    }

    pub const Iter = struct {
        l: *Ledger,
        a: std.mem.Allocator,
        prefix: []const u8,
        at: usize = 0,
        cur: ?btree.Tree.Cursor = null,

        pub fn next(it: *Iter) ?Entry {
            switch (it.l.backend) {
                .journal => |*j| {
                    if (it.at >= j.entries.items.len) return null;
                    const e = j.entries.items[it.at];
                    if (!std.mem.startsWith(u8, e.key, it.prefix)) return null;
                    it.at += 1;
                    return .{ .key = e.key, .val = e.val };
                },
                .btree => {
                    const c = &(it.cur orelse return null);
                    const e = (c.next(it.a) catch null) orelse return null;
                    if (!std.mem.startsWith(u8, e.key, it.prefix)) {
                        it.cur = null;
                        return null;
                    }
                    return .{ .key = e.key, .val = e.val };
                },
            }
        }
    };

    /// Все записи, чей ключ начинается с `prefix`, по порядку ключей.
    /// Между `next` хранилище не меняют.
    pub fn scan(l: *Ledger, a: std.mem.Allocator, prefix: []const u8) Iter {
        var it = Iter{ .l = l, .a = a, .prefix = prefix };
        switch (l.backend) {
            .journal => |*j| it.at = j.seek(prefix),
            .btree => |*t| it.cur = t.seek(prefix) catch null,
        }
        return it;
    }

    pub fn count(l: *Ledger, a: std.mem.Allocator, prefix: []const u8) usize {
        var it = l.scan(a, prefix);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }
};

// ───────────── поля значения ─────────────

/// n-е поле значения (с нуля); нет такого — пустая строка.
pub fn field(val: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, val, sep);
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) if (i == n) return f;
    return "";
}

pub fn fieldInt(val: []const u8, n: usize) i64 {
    return std.fmt.parseInt(i64, field(val, n), 10) catch 0;
}

/// Значение из полей: строки как есть, целые — десятичной записью.
pub fn rec(a: std.mem.Allocator, fields: anytype) []const u8 {
    var list = std.ArrayList(u8).init(a);
    inline for (fields, 0..) |f, i| {
        if (i > 0) list.append(sep) catch return "";
        switch (@typeInfo(@TypeOf(f))) {
            .int, .comptime_int => list.writer().print("{d}", .{f}) catch return "",
            .bool => list.append(if (f) '1' else '0') catch return "",
            else => list.appendSlice(f) catch return "",
        }
    }
    return list.items;
}

// ───────────── ключи ─────────────

/// Номер в ключе: знак и десять цифр. Положительные идут раньше отрицательных,
/// те и другие — по возрастанию модуля, то есть в порядке создания.
pub fn num(buf: *[11]u8, id: i64) []const u8 {
    const mag: u64 = @abs(id);
    return std.fmt.bufPrint(buf, "{c}{d:0>10}", .{ @as(u8, if (id < 0) '-' else '+'), mag }) catch unreachable;
}

pub fn parseNum(s: []const u8) i64 {
    if (s.len < 2) return 0;
    const mag = std.fmt.parseInt(i64, s[1..], 10) catch return 0;
    return if (s[0] == '-') -mag else mag;
}

/// Ключ: буква вида и части — строки или номера.
pub fn key(a: std.mem.Allocator, comptime kind: []const u8, parts: anytype) []const u8 {
    var list = std.ArrayList(u8).init(a);
    list.appendSlice(kind) catch return "";
    inline for (parts) |p| {
        switch (@typeInfo(@TypeOf(p))) {
            .int, .comptime_int => {
                var b: [11]u8 = undefined;
                list.appendSlice(num(&b, p)) catch return "";
            },
            else => list.appendSlice(p) catch return "",
        }
    }
    return list.items;
}

test "одна история — одинаковый результат в обоих хранилищах" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dumps: [2][]const u8 = undefined;
    for ([_]Kind{ .journal, .btree }, 0..) |kind, n| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var prng = std.Random.DefaultPrng.init(42);
        const rnd = prng.random();
        var round: usize = 0;
        while (round < 3) : (round += 1) { // с перезапуском между кругами
            var l = try Ledger.open(gpa, tmp.dir, kind);
            defer l.close();
            var i: usize = 0;
            while (i < 800) : (i += 1) {
                const k = key(a, "D", .{@as(i64, rnd.intRangeAtMost(i64, -40, 40))});
                if (rnd.uintLessThan(u8, 5) == 0) l.del(k) else {
                    const v = try a.alloc(u8, if (rnd.uintLessThan(u8, 20) == 0) 5000 else rnd.uintLessThan(usize, 200));
                    for (v) |*c| c.* = rnd.intRangeAtMost(u8, 'a', 'z');
                    l.put(k, rec(a, .{ "t", i, v }));
                }
                if (i % 37 == 0) try l.flush();
            }
            try l.flush();
        }
        var l = try Ledger.open(gpa, tmp.dir, kind);
        defer l.close();
        var out = std.ArrayList(u8).init(a);
        var it = l.scan(a, "D");
        while (it.next()) |e| try out.writer().print("{s}={s}\n", .{ e.key, e.val });
        dumps[n] = out.items;
    }
    try std.testing.expect(dumps[0].len > 1000);
    try std.testing.expectEqualStrings(dumps[0], dumps[1]);
}

test "поля и ключи" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = rec(a, .{ "название", 42, true, "" });
    try std.testing.expectEqualStrings("название", field(v, 0));
    try std.testing.expectEqual(@as(i64, 42), fieldInt(v, 1));
    try std.testing.expectEqualStrings("1", field(v, 2));
    try std.testing.expectEqualStrings("C+0000000002-0000000101", key(a, "C", .{ 2, -101 }));
    try std.testing.expect(std.mem.order(u8, key(a, "D", .{5}), key(a, "D", .{-1})) == .lt);
}
