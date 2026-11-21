//! Кэш распакованных кадров с бюджетом памяти и вытеснением S3-FIFO
//! (Yang и др., SOSP 2023): новый кадр попадает в малую очередь; оттуда
//! уходит в основную, только если к нему обращались снова, иначе вытесняется,
//! а его ключ запоминается в «призраках» — при возвращении он идёт сразу
//! в основную очередь. Вся память выделяется один раз в `init`.

const std = @import("std");

fn Ring(comptime T: type) type {
    return struct {
        items: []T,
        head: usize = 0,
        len: usize = 0,

        fn push(r: *@This(), v: T) void {
            r.items[(r.head + r.len) % r.items.len] = v;
            r.len += 1;
        }
        fn pop(r: *@This()) T {
            const v = r.items[r.head];
            r.head = (r.head + 1) % r.items.len;
            r.len -= 1;
            return v;
        }
    };
}

pub fn S3Fifo(comptime slot_bytes: usize) type {
    return struct {
        const Self = @This();
        const Where = enum(u8) { free, small, main };
        const Slot = struct { key: u64 = 0, len: u32 = 0, freq: u8 = 0, where: Where = .free };

        slots: []Slot,
        data: []u8,
        map: std.AutoHashMapUnmanaged(u64, u32) = .{},
        small: Ring(u32),
        main: Ring(u32),
        ghost: Ring(u64),
        ghost_set: std.AutoHashMapUnmanaged(u64, void) = .{},
        free: Ring(u32),
        small_cap: usize,
        hits: u64 = 0,
        misses: u64 = 0,

        pub fn init(gpa: std.mem.Allocator, budget_bytes: usize) !Self {
            const cap: u32 = @intCast(@max(8, budget_bytes / slot_bytes));
            var c = Self{
                .slots = try gpa.alloc(Slot, cap),
                .data = try gpa.alloc(u8, @as(usize, cap) * slot_bytes),
                .small = .{ .items = try gpa.alloc(u32, cap) },
                .main = .{ .items = try gpa.alloc(u32, cap) },
                .ghost = .{ .items = try gpa.alloc(u64, cap) },
                .free = .{ .items = try gpa.alloc(u32, cap) },
                .small_cap = @max(1, cap / 10),
            };
            @memset(c.slots, .{});
            try c.map.ensureTotalCapacity(gpa, cap);
            try c.ghost_set.ensureTotalCapacity(gpa, cap);
            for (0..cap) |i| c.free.push(@intCast(i));
            return c;
        }

        pub fn deinit(c: *Self, gpa: std.mem.Allocator) void {
            gpa.free(c.slots);
            gpa.free(c.data);
            gpa.free(c.small.items);
            gpa.free(c.main.items);
            gpa.free(c.ghost.items);
            gpa.free(c.free.items);
            c.map.deinit(gpa);
            c.ghost_set.deinit(gpa);
        }

        /// Срез живёт до следующего `put`.
        pub fn get(c: *Self, key: u64) ?[]const u8 {
            const i = c.map.get(key) orelse {
                c.misses += 1;
                return null;
            };
            c.hits += 1;
            const s = &c.slots[i];
            if (s.freq < 3) s.freq += 1;
            return c.data[@as(usize, i) * slot_bytes ..][0..s.len];
        }

        fn evict(c: *Self) u32 {
            while (true) {
                if (c.small.len > 0 and (c.small.len >= c.small_cap or c.main.len == 0)) {
                    const i = c.small.pop();
                    const s = &c.slots[i];
                    if (s.freq > 1) {
                        s.where = .main;
                        s.freq = 0;
                        c.main.push(i);
                        continue;
                    }
                    if (c.ghost.len == c.ghost.items.len) _ = c.ghost_set.remove(c.ghost.pop());
                    c.ghost.push(s.key);
                    c.ghost_set.putAssumeCapacity(s.key, {});
                    _ = c.map.remove(s.key);
                    return i;
                }
                const i = c.main.pop();
                const s = &c.slots[i];
                if (s.freq > 0) {
                    s.freq -= 1;
                    c.main.push(i);
                    continue;
                }
                _ = c.map.remove(s.key);
                return i;
            }
        }

        /// Место под значение `key` длиной `len`: вызывающий заполняет его сам.
        pub fn put(c: *Self, key: u64, len: usize) []u8 {
            std.debug.assert(len <= slot_bytes);
            const i = c.map.get(key) orelse blk: {
                const i = if (c.free.len > 0) c.free.pop() else c.evict();
                const s = &c.slots[i];
                s.key = key;
                s.freq = 0;
                if (c.ghost_set.contains(key)) {
                    s.where = .main;
                    c.main.push(i);
                } else {
                    s.where = .small;
                    c.small.push(i);
                }
                c.map.putAssumeCapacity(key, i);
                break :blk i;
            };
            c.slots[i].len = @intCast(len);
            return c.data[@as(usize, i) * slot_bytes ..][0..len];
        }

        pub fn clear(c: *Self) void {
            c.map.clearRetainingCapacity();
            c.ghost_set.clearRetainingCapacity();
            c.small.len = 0;
            c.main.len = 0;
            c.ghost.len = 0;
            c.free.len = 0;
            c.free.head = 0;
            for (0..c.slots.len) |i| c.free.push(@intCast(i));
        }
    };
}

test "s3-fifo: горячее остаётся, бюджет соблюдается" {
    const gpa = std.testing.allocator;
    var c = try S3Fifo(16).init(gpa, 16 * 20);
    defer c.deinit(gpa);
    // горячие ключи 0..4 читаются постоянно, холодные идут потоком
    var k: u64 = 0;
    while (k < 5) : (k += 1) @memset(c.put(k, 16), @intCast(k));
    var cold: u64 = 100;
    while (cold < 600) : (cold += 1) {
        k = 0;
        while (k < 5) : (k += 1) {
            if (c.get(k) == null) @memset(c.put(k, 16), @intCast(k));
        }
        @memset(c.put(cold, 8), 0xEE);
    }
    try std.testing.expect(c.map.count() <= 20);
    k = 0;
    while (k < 5) : (k += 1) try std.testing.expectEqual(@as(u8, @intCast(k)), c.get(k).?[0]);
    try std.testing.expect(c.get(101) == null);
    try std.testing.expect(c.hits > c.misses);
}
