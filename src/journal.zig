//! Хранилище записей по умолчанию: журнал `clipper.journal` — файл строк,
//! в который только дописывают, — и всё состояние в памяти.
//!
//! Строка — поля через табуляцию и контрольная сумма:
//!
//!     +  →  ключ  →  значение  →  #3e1f0a2b        (→ — табуляция)
//!     -  →  ключ  →  #9c0d11aa
//!
//! Табуляции, переводы строк и обратные косые в полях экранированы. Строка
//! без перевода строки в конце — запись, оборванная сбоем: читатель
//! останавливается перед ней, следующий писатель её обрезает. Строка с
//! неверной суммой пропускается и считается.
//!
//! Писатель (сервер или команда `clipper …`) берёт блокировку файла,
//! дочитывает чужие записи, дописывает свои, сбрасывает на диск и отпускает.

const std = @import("std");
const sys = @import("sys.zig");

pub const file_name = "clipper.journal";

pub const Entry = struct { key: []u8, val: []u8 };

pub const Journal = struct {
    gpa: std.mem.Allocator,
    file: std.fs.File,
    /// Отсортировано по ключу.
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// Сколько байт файла прочитано и применено.
    applied: u64 = 0,
    damaged: u32 = 0,
    records: u64 = 0,
    /// Строки, ещё не записанные в файл (до `flush`).
    pending: std.ArrayListUnmanaged(u8) = .{},
    /// Блокировка файла взята надолго (hold): flush её не трогает.
    held: bool = false,

    pub fn open(gpa: std.mem.Allocator, dir: std.fs.Dir) !Journal {
        const file = try dir.createFile(file_name, .{ .read = true, .truncate = false });
        var j = Journal{ .gpa = gpa, .file = file };
        errdefer j.close();
        _ = try j.catchUp();
        return j;
    }

    pub fn close(j: *Journal) void {
        for (j.entries.items) |e| {
            j.gpa.free(e.key);
            j.gpa.free(e.val);
        }
        j.entries.deinit(j.gpa);
        j.pending.deinit(j.gpa);
        j.file.close();
    }

    fn lowerBound(j: *const Journal, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = j.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, j.entries.items[mid].key, key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn get(j: *const Journal, key: []const u8) ?[]const u8 {
        const i = j.lowerBound(key);
        if (i < j.entries.items.len and std.mem.eql(u8, j.entries.items[i].key, key)) return j.entries.items[i].val;
        return null;
    }

    /// Первая запись с ключом ≥ `key`.
    pub fn seek(j: *const Journal, key: []const u8) usize {
        return j.lowerBound(key);
    }

    fn applyPut(j: *Journal, key: []const u8, val: []const u8) !void {
        const i = j.lowerBound(key);
        const v = try j.gpa.dupe(u8, val);
        errdefer j.gpa.free(v);
        if (i < j.entries.items.len and std.mem.eql(u8, j.entries.items[i].key, key)) {
            j.gpa.free(j.entries.items[i].val);
            j.entries.items[i].val = v;
            return;
        }
        const k = try j.gpa.dupe(u8, key);
        errdefer j.gpa.free(k);
        try j.entries.insert(j.gpa, i, .{ .key = k, .val = v });
    }

    fn applyDel(j: *Journal, key: []const u8) void {
        const i = j.lowerBound(key);
        if (i < j.entries.items.len and std.mem.eql(u8, j.entries.items[i].key, key)) {
            const e = j.entries.orderedRemove(i);
            j.gpa.free(e.key);
            j.gpa.free(e.val);
        }
    }

    pub fn put(j: *Journal, key: []const u8, val: []const u8) !void {
        try j.applyPut(key, val);
        try format(j.gpa, &j.pending, &.{ "+", key, val });
    }

    pub fn del(j: *Journal, key: []const u8) !void {
        j.applyDel(key);
        try format(j.gpa, &j.pending, &.{ "-", key });
    }

    /// Дочитывает записи, дописанные другим процессом. true — что-то применено.
    pub fn catchUp(j: *Journal) !bool {
        const end = try j.file.getEndPos();
        if (end <= j.applied) return false;
        const bytes = try j.gpa.alloc(u8, @intCast(end - j.applied));
        defer j.gpa.free(bytes);
        const n = try j.file.preadAll(bytes, j.applied);
        var scratch = std.ArrayList(u8).init(j.gpa);
        defer scratch.deinit();
        var pos: usize = 0;
        var any = false;
        while (std.mem.indexOfScalarPos(u8, bytes[0..n], pos, '\n')) |nl| {
            const line = bytes[pos..nl];
            pos = nl + 1;
            var fields: [3][]const u8 = undefined;
            const f = parse(line, &fields, &scratch) orelse {
                j.damaged += 1;
                continue;
            };
            j.records += 1;
            any = true;
            if (f.len == 3 and f[0].len == 1 and f[0][0] == '+') {
                try j.applyPut(f[1], f[2]);
            } else if (f.len == 2 and f[0].len == 1 and f[0][0] == '-') {
                j.applyDel(f[1]);
            } else j.damaged += 1;
        }
        j.applied += pos;
        return any;
    }

    /// Берёт блокировку файла до release и дочитывает чужие записи: всё, что
    /// прочитано после этого, не устареет, пока блокировка не отпущена.
    /// true — применены чужие записи.
    pub fn hold(j: *Journal) !bool {
        if (j.held) return false;
        try sys.lock(j.file);
        j.held = true;
        errdefer j.release();
        return try j.catchUp();
    }

    pub fn release(j: *Journal) void {
        if (!j.held) return;
        j.held = false;
        sys.unlock(j.file);
    }

    /// Записывает накопленные строки и сбрасывает файл на диск.
    /// true — по дороге пришлось применить чужие записи.
    pub fn flush(j: *Journal) !bool {
        if (j.pending.items.len == 0) return false;
        if (!j.held) try sys.lock(j.file);
        defer if (!j.held) sys.unlock(j.file);
        const foreign = try j.catchUp();
        const end = try j.file.getEndPos();
        if (end > j.applied) try j.file.setEndPos(j.applied); // оборванный хвост: под блокировкой больше никто не пишет
        try j.file.pwriteAll(j.pending.items, j.applied);
        try j.file.sync();
        j.applied += j.pending.items.len;
        j.pending.clearRetainingCapacity();
        return foreign;
    }
};

fn escape(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    try out.ensureUnusedCapacity(gpa, field.len + 8);
    for (field) |c| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => try out.append(gpa, c),
    };
}

pub fn format(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    for (fields) |f| {
        try escape(gpa, out, f);
        try out.append(gpa, '\t');
    }
    const crc = std.hash.Crc32.hash(out.items[start..]);
    var tail: [10]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&tail, "#{x:0>8}\n", .{crc}) catch unreachable);
}

/// Делит строку и снимает экранирование; null — сумма не сошлась.
/// Поля указывают в `scratch` и живут до следующего вызова.
pub fn parse(line: []const u8, fields: *[3][]const u8, scratch: *std.ArrayList(u8)) ?[]const []const u8 {
    if (line.len < 9) return null;
    const hash_at = line.len - 9;
    if (line[hash_at] != '#') return null;
    const want = std.fmt.parseInt(u32, line[hash_at + 1 ..], 16) catch return null;
    const body = line[0..hash_at];
    if (std.hash.Crc32.hash(body) != want) return null;
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(body.len) catch return null;
    var bounds: [3][2]usize = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\t') {
            if (count == 3) return null;
            bounds[count] = .{ start, scratch.items.len };
            count += 1;
            start = scratch.items.len;
        } else if (c == '\\' and i + 1 < body.len) {
            i += 1;
            scratch.appendAssumeCapacity(switch (body[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                else => body[i],
            });
        } else scratch.appendAssumeCapacity(c);
    }
    for (bounds[0..count], 0..) |b, k| fields[k] = scratch.items[b[0]..b[1]];
    return fields[0..count];
}

test "запись переживает дорогу, испорченная ловится" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(gpa);
    try format(gpa, &out, &.{ "+", "a\tb", "line\nbreak\\" });
    var fields: [3][]const u8 = undefined;
    var scratch = std.ArrayList(u8).init(gpa);
    defer scratch.deinit();
    const got = parse(out.items[0 .. out.items.len - 1], &fields, &scratch).?;
    try std.testing.expectEqualStrings("a\tb", got[1]);
    try std.testing.expectEqualStrings("line\nbreak\\", got[2]);
    out.items[2] = 'X';
    try std.testing.expect(parse(out.items[0 .. out.items.len - 1], &fields, &scratch) == null);
}

test "журнал переживает перезапуск и обрыв" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    {
        var j = try Journal.open(gpa, tmp.dir);
        defer j.close();
        try j.put("b", "2");
        try j.put("a", "1");
        try j.put("c", "3");
        try j.del("c");
        _ = try j.flush();
        // оборванная запись после сбоя
        try j.file.pwriteAll("+\tz\tzz", try j.file.getEndPos());
    }
    {
        var j = try Journal.open(gpa, tmp.dir);
        defer j.close();
        try std.testing.expectEqual(@as(usize, 2), j.entries.items.len);
        try std.testing.expectEqualStrings("1", j.get("a").?);
        try std.testing.expect(j.get("z") == null);
        try j.put("d", "4");
        _ = try j.flush(); // хвост обрезан, запись легла на его место
    }
    var j = try Journal.open(gpa, tmp.dir);
    defer j.close();
    try std.testing.expectEqual(@as(usize, 3), j.entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), j.damaged);
}
