//! Хранилище записей `-btree`: B+ дерево copy-on-write в одном файле
//! `clipper.tree`.
//!
//!   страницы 0, 1   мета-страницы, пишутся по очереди: номер транзакции,
//!                   корень, число страниц, контрольная сумма — действует
//!                   верная с большим номером
//!   страницы 2…     ветви, листья и страницы длинных значений
//!
//! Ключ — до 255 байт, порядок побайтовый. Значение до 1 КБ лежит в листе,
//! длиннее — в цепочке страниц.
//!
//! Запись: один писатель под блокировкой файла. Страница, до которой может
//! довести мета-страница, никогда не переписывается: транзакция копирует то,
//! что меняет (свои же новые страницы меняет на месте), пишет их, сбрасывает
//! файл и только потом пишет другую мета-страницу. Сбой в любой момент
//! оставляет прежнее дерево целым.
//!
//! Чтение: без блокировок; записанная страница неизменна, поэтому кэш
//! страниц никогда не устаревает. Освободившиеся страницы повторно не
//! используются — файл уплотняется при открытии (`compact`).

const std = @import("std");
const sys = @import("sys.zig");

pub const file_name = "clipper.tree";
pub const page_size = 4096;
pub const max_key = 255;
pub const max_inline = 1024;
const magic = "CLIPTREE".*;
const version: u32 = 1;
const cache_pages = 512;
const ovf_data = page_size - 7;

const Page = [page_size]u8;

const Meta = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    root: u32 = 0,
    txn: u64 = 0,
    pages: u32 = 2,
    crc: u32 = 0,

    fn sum(m: *const Meta) u32 {
        return std.hash.Crc32.hash(std.mem.asBytes(m)[0..@offsetOf(Meta, "crc")]);
    }
    fn valid(m: *const Meta) bool {
        return std.mem.eql(u8, &m.magic, &magic) and m.version == version and m.crc == m.sum() and m.pages >= 2 and m.root < m.pages;
    }
};

pub const Entry = struct { key: []const u8, val: []const u8 };

const Item = struct {
    key: []const u8,
    /// лист: значение в странице или цепочка
    val: []const u8 = "",
    ovf: u32 = 0,
    vlen: u32 = 0,
    /// ветвь: потомок справа от ключа
    child: u32 = 0,

    fn leafSize(it: Item) usize {
        return 6 + it.key.len + if (it.ovf != 0) @as(usize, 4) else it.val.len;
    }
};

const Up = struct { left: u32, sep: []const u8 = "", right: u32 = 0 };

pub const Tree = struct {
    gpa: std.mem.Allocator,
    file: std.fs.File,
    meta: Meta = .{},
    cache: []Page,
    tags: []u32,
    /// Страницы текущей транзакции.
    dirty: std.AutoHashMapUnmanaged(u32, *Page) = .{},
    scratch: std.heap.ArenaAllocator,
    in_txn: bool = false,
    root: u32 = 0,
    pages: u32 = 2,

    pub fn open(gpa: std.mem.Allocator, dir: std.fs.Dir) !Tree {
        const file = try dir.createFile(file_name, .{ .read = true, .truncate = false });
        errdefer file.close();
        var t = Tree{
            .gpa = gpa,
            .file = file,
            .cache = try gpa.alloc(Page, cache_pages),
            .tags = try gpa.alloc(u32, cache_pages),
            .scratch = std.heap.ArenaAllocator.init(gpa),
        };
        @memset(t.tags, 0);
        errdefer {
            gpa.free(t.cache);
            gpa.free(t.tags);
        }
        if (try file.getEndPos() < 2 * page_size) {
            // Новый файл: две мета-страницы пустого дерева.
            try sys.lock(file);
            defer sys.unlock(file);
            if (try file.getEndPos() < 2 * page_size) {
                var pg: Page = [_]u8{0} ** page_size;
                var m = Meta{};
                m.crc = m.sum();
                @memcpy(pg[0..@sizeOf(Meta)], std.mem.asBytes(&m));
                try file.pwriteAll(&pg, 0);
                try file.pwriteAll(&pg, page_size);
                try file.sync();
            }
        }
        _ = try t.refresh();
        return t;
    }

    pub fn close(t: *Tree) void {
        t.abort();
        t.dirty.deinit(t.gpa);
        t.scratch.deinit();
        t.gpa.free(t.cache);
        t.gpa.free(t.tags);
        t.file.close();
    }

    /// Перечитывает мета-страницы. true — дерево изменилось (другим процессом).
    pub fn refresh(t: *Tree) !bool {
        var two: [2 * page_size]u8 = undefined;
        if (try t.file.preadAll(&two, 0) != two.len) return error.Damaged;
        var best: ?Meta = null;
        for (0..2) |i| {
            var m: Meta = undefined;
            @memcpy(std.mem.asBytes(&m), two[i * page_size ..][0..@sizeOf(Meta)]);
            if (!m.valid()) continue;
            if (best == null or m.txn > best.?.txn) best = m;
        }
        const m = best orelse return error.Damaged;
        const changed = m.txn != t.meta.txn or m.root != t.meta.root;
        t.meta = m;
        if (!t.in_txn) {
            t.root = m.root;
            t.pages = m.pages;
        }
        return changed;
    }

    fn page(t: *Tree, no: u32) !*const Page {
        if (t.dirty.get(no)) |p| return p;
        if (no < 2 or no >= t.pages) return error.Damaged;
        const slot = no % cache_pages;
        if (t.tags[slot] != no) {
            t.tags[slot] = 0;
            if (try t.file.preadAll(&t.cache[slot], @as(u64, no) * page_size) != page_size) return error.Damaged;
            t.tags[slot] = no;
        }
        return &t.cache[slot];
    }

    // ───────────── чтение ─────────────

    const LeafIt = struct {
        pg: *const Page,
        left: u16,
        off: usize = 3,

        fn init(pg: *const Page) !LeafIt {
            if (pg[0] != 1) return error.Damaged;
            return .{ .pg = pg, .left = std.mem.readInt(u16, pg[1..3], .little) };
        }

        fn next(it: *LeafIt) !?Item {
            if (it.left == 0) return null;
            it.left -= 1;
            const o = it.off;
            if (o + 6 > page_size) return error.Damaged;
            const klen: usize = it.pg[o];
            const kind = it.pg[o + 1];
            const vlen = std.mem.readInt(u32, it.pg[o + 2 ..][0..4], .little);
            const body: usize = if (kind == 0) vlen else 4;
            if (kind > 1 or o + 6 + klen + body > page_size) return error.Damaged;
            const key = it.pg[o + 6 ..][0..klen];
            it.off = o + 6 + klen + body;
            if (kind == 0) return .{ .key = key, .val = it.pg[o + 6 + klen ..][0..vlen], .vlen = vlen };
            const first = std.mem.readInt(u32, it.pg[o + 6 + klen ..][0..4], .little);
            if (first < 2) return error.Damaged;
            return .{ .key = key, .ovf = first, .vlen = vlen };
        }
    };

    const BranchIt = struct {
        pg: *const Page,
        left: u16,
        off: usize = 7,

        fn init(pg: *const Page) !BranchIt {
            if (pg[0] != 2) return error.Damaged;
            return .{ .pg = pg, .left = std.mem.readInt(u16, pg[1..3], .little) };
        }

        fn first(it: *const BranchIt) u32 {
            return std.mem.readInt(u32, it.pg[3..7], .little);
        }

        fn next(it: *BranchIt) !?Item {
            if (it.left == 0) return null;
            it.left -= 1;
            const o = it.off;
            if (o + 1 > page_size) return error.Damaged;
            const klen: usize = it.pg[o];
            if (o + 1 + klen + 4 > page_size) return error.Damaged;
            it.off = o + 1 + klen + 4;
            return .{ .key = it.pg[o + 1 ..][0..klen], .child = std.mem.readInt(u32, it.pg[o + 1 + klen ..][0..4], .little) };
        }
    };

    fn readValue(t: *Tree, a: std.mem.Allocator, it: Item) ![]u8 {
        if (it.ovf == 0) return a.dupe(u8, it.val);
        if (it.vlen > 64 << 20) return error.Damaged;
        const out = try a.alloc(u8, it.vlen);
        var no = it.ovf;
        var at: usize = 0;
        while (at < out.len) {
            const pg = try t.page(no);
            if (pg[0] != 3) return error.Damaged;
            const n: usize = std.mem.readInt(u16, pg[5..7], .little);
            if (n == 0 or n > ovf_data or at + n > out.len) return error.Damaged;
            @memcpy(out[at..][0..n], pg[7..][0..n]);
            at += n;
            no = std.mem.readInt(u32, pg[1..5], .little);
        }
        return out;
    }

    /// Номер потомка, в чьём поддереве лежит `key`, и его порядковый номер.
    fn childFor(pg: *const Page, key: []const u8) !struct { u32, u16 } {
        var it = try BranchIt.init(pg);
        var child = it.first();
        var idx: u16 = 0;
        while (try it.next()) |x| {
            if (std.mem.order(u8, key, x.key) == .lt) break;
            child = x.child;
            idx += 1;
        }
        return .{ child, idx };
    }

    pub fn get(t: *Tree, a: std.mem.Allocator, key: []const u8) !?[]u8 {
        var no = t.root;
        if (no == 0) return null;
        var depth: usize = 0;
        while (true) : (depth += 1) {
            if (depth > 16) return error.Damaged;
            const pg = try t.page(no);
            if (pg[0] == 2) {
                no = (try childFor(pg, key))[0];
                continue;
            }
            var it = try LeafIt.init(pg);
            while (try it.next()) |x| {
                switch (std.mem.order(u8, x.key, key)) {
                    .lt => {},
                    .eq => return try t.readValue(a, x),
                    .gt => return null,
                }
            }
            return null;
        }
    }

    pub const Cursor = struct {
        t: *Tree,
        stack: [16]struct { no: u32, idx: u16 } = undefined,
        depth: u8 = 0,
        leaf: u32 = 0,
        /// сколько записей листа уже пройдено
        at: u16 = 0,

        fn descend(c: *Cursor, start: u32, key: ?[]const u8) !void {
            var no = start;
            while (true) {
                const pg = try c.t.page(no);
                if (pg[0] != 2) break;
                if (c.depth == c.stack.len) return error.Damaged;
                const child, const idx = if (key) |k| try childFor(pg, k) else .{ (try BranchIt.init(pg)).first(), @as(u16, 0) };
                c.stack[c.depth] = .{ .no = no, .idx = idx };
                c.depth += 1;
                no = child;
            }
            c.leaf = no;
            c.at = 0;
            if (key) |k| {
                var it = try LeafIt.init(try c.t.page(no));
                while (try it.next()) |x| {
                    if (std.mem.order(u8, x.key, k) != .lt) break;
                    c.at += 1;
                }
            }
        }

        pub fn next(c: *Cursor, a: std.mem.Allocator) !?Entry {
            while (c.leaf != 0) {
                var it = try LeafIt.init(try c.t.page(c.leaf));
                var skip = c.at;
                while (skip > 0) : (skip -= 1) _ = try it.next();
                if (try it.next()) |x| {
                    c.at += 1;
                    const key = try a.dupe(u8, x.key);
                    // readValue может вытеснить страницу листа из кэша: ключ уже скопирован
                    var copy = x;
                    if (x.ovf == 0) copy.val = try a.dupe(u8, x.val);
                    const val = if (x.ovf == 0) copy.val else try c.t.readValue(a, x);
                    return .{ .key = key, .val = val };
                }
                // лист кончился: следующий потомок ближайшего предка
                c.leaf = 0;
                while (c.depth > 0) {
                    const top = &c.stack[c.depth - 1];
                    var bit = try BranchIt.init(try c.t.page(top.no));
                    const nkeys = bit.left;
                    if (top.idx < nkeys) {
                        top.idx += 1;
                        var k: u16 = 0;
                        var child: u32 = 0;
                        while (k < top.idx) : (k += 1) child = (try bit.next()).?.child;
                        try c.descend(child, null);
                        break;
                    }
                    c.depth -= 1;
                }
            }
            return null;
        }
    };

    /// Курсор на первой записи с ключом ≥ `key`.
    pub fn seek(t: *Tree, key: []const u8) !Cursor {
        var c = Cursor{ .t = t };
        if (t.root != 0) try c.descend(t.root, key);
        return c;
    }

    // ───────────── запись ─────────────

    fn begin(t: *Tree) !void {
        if (t.in_txn) return;
        try sys.lock(t.file);
        errdefer sys.unlock(t.file);
        _ = try t.refresh();
        t.root = t.meta.root;
        t.pages = t.meta.pages;
        t.in_txn = true;
    }

    /// Начинает транзакцию заранее: блокировка файла и свежее дерево — до
    /// commit или release. true — дерево с прошлого раза изменил другой процесс.
    pub fn hold(t: *Tree) !bool {
        if (t.in_txn) return false;
        const txn = t.meta.txn;
        try t.begin();
        return t.meta.txn != txn;
    }

    /// Отпускает блокировку, если транзакция так и не записана.
    pub fn release(t: *Tree) void {
        t.abort();
    }

    pub fn abort(t: *Tree) void {
        if (!t.in_txn) return;
        var it = t.dirty.valueIterator();
        while (it.next()) |p| t.gpa.destroy(p.*);
        t.dirty.clearRetainingCapacity();
        _ = t.scratch.reset(.retain_capacity);
        t.in_txn = false;
        t.root = t.meta.root;
        t.pages = t.meta.pages;
        sys.unlock(t.file);
    }

    pub fn commit(t: *Tree) !void {
        if (!t.in_txn) return;
        errdefer t.abort();
        var it = t.dirty.iterator();
        while (it.next()) |e| try t.file.pwriteAll(e.value_ptr.*, @as(u64, e.key_ptr.*) * page_size);
        try t.file.sync();
        var m = Meta{ .root = t.root, .txn = t.meta.txn + 1, .pages = t.pages };
        m.crc = m.sum();
        var pg: Page = [_]u8{0} ** page_size;
        @memcpy(pg[0..@sizeOf(Meta)], std.mem.asBytes(&m));
        try t.file.pwriteAll(&pg, (m.txn % 2) * page_size);
        try t.file.sync();
        t.meta = m;
        var vit = t.dirty.valueIterator();
        while (vit.next()) |p| t.gpa.destroy(p.*);
        t.dirty.clearRetainingCapacity();
        _ = t.scratch.reset(.retain_capacity);
        t.in_txn = false;
        sys.unlock(t.file);
    }

    fn newPage(t: *Tree) !struct { u32, *Page } {
        const p = try t.gpa.create(Page);
        errdefer t.gpa.destroy(p);
        @memset(p, 0);
        const no = t.pages;
        try t.dirty.put(t.gpa, no, p);
        t.pages += 1;
        return .{ no, p };
    }

    /// Страница для новой версии узла `old`: своя же, если узел создан в этой транзакции.
    fn pageFor(t: *Tree, old: u32) !struct { u32, *Page } {
        if (old != 0) if (t.dirty.get(old)) |p| {
            @memset(p, 0);
            return .{ old, p };
        };
        return t.newPage();
    }

    fn decodeLeaf(t: *Tree, no: u32) !std.ArrayList(Item) {
        const a = t.scratch.allocator();
        var list = std.ArrayList(Item).init(a);
        if (no == 0) return list;
        const copy = try a.create(Page);
        copy.* = (try t.page(no)).*;
        var it = try LeafIt.init(copy);
        while (try it.next()) |x| try list.append(x);
        return list;
    }

    fn encodeLeaf(pg: *Page, items: []const Item) void {
        pg[0] = 1;
        std.mem.writeInt(u16, pg[1..3], @intCast(items.len), .little);
        var o: usize = 3;
        for (items) |x| {
            pg[o] = @intCast(x.key.len);
            pg[o + 1] = if (x.ovf != 0) 1 else 0;
            std.mem.writeInt(u32, pg[o + 2 ..][0..4], x.vlen, .little);
            @memcpy(pg[o + 6 ..][0..x.key.len], x.key);
            o += 6 + x.key.len;
            if (x.ovf != 0) {
                std.mem.writeInt(u32, pg[o..][0..4], x.ovf, .little);
                o += 4;
            } else {
                @memcpy(pg[o..][0..x.val.len], x.val);
                o += x.val.len;
            }
        }
    }

    fn writeLeaf(t: *Tree, old: u32, items: []const Item) !Up {
        var total: usize = 3;
        for (items) |x| total += x.leafSize();
        const no, const pg = try t.pageFor(old);
        if (total <= page_size) {
            encodeLeaf(pg, items);
            return .{ .left = no };
        }
        var acc: usize = 3;
        var cut: usize = 0;
        while (cut < items.len - 1 and acc < total / 2) : (cut += 1) acc += items[cut].leafSize();
        if (cut == 0) cut = 1;
        encodeLeaf(pg, items[0..cut]);
        const rno, const rpg = try t.newPage();
        encodeLeaf(rpg, items[cut..]);
        return .{ .left = no, .sep = items[cut].key, .right = rno };
    }

    const Branch = struct { first: u32, items: std.ArrayList(Item) };

    fn decodeBranch(t: *Tree, no: u32) !Branch {
        const a = t.scratch.allocator();
        const copy = try a.create(Page);
        copy.* = (try t.page(no)).*;
        var it = try BranchIt.init(copy);
        var b = Branch{ .first = it.first(), .items = std.ArrayList(Item).init(a) };
        while (try it.next()) |x| try b.items.append(x);
        return b;
    }

    fn encodeBranch(pg: *Page, first: u32, items: []const Item) void {
        pg[0] = 2;
        std.mem.writeInt(u16, pg[1..3], @intCast(items.len), .little);
        std.mem.writeInt(u32, pg[3..7], first, .little);
        var o: usize = 7;
        for (items) |x| {
            pg[o] = @intCast(x.key.len);
            @memcpy(pg[o + 1 ..][0..x.key.len], x.key);
            std.mem.writeInt(u32, pg[o + 1 + x.key.len ..][0..4], x.child, .little);
            o += 5 + x.key.len;
        }
    }

    fn writeBranch(t: *Tree, old: u32, first: u32, items: []const Item) !Up {
        var total: usize = 7;
        for (items) |x| total += 5 + x.key.len;
        const no, const pg = try t.pageFor(old);
        if (total <= page_size) {
            encodeBranch(pg, first, items);
            return .{ .left = no };
        }
        // Средний ключ уходит наверх.
        const mid = items.len / 2;
        encodeBranch(pg, first, items[0..mid]);
        const rno, const rpg = try t.newPage();
        encodeBranch(rpg, items[mid].child, items[mid + 1 ..]);
        return .{ .left = no, .sep = items[mid].key, .right = rno };
    }

    fn findItem(items: []const Item, key: []const u8) struct { usize, bool } {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, items[mid].key, key)) {
                .lt => lo = mid + 1,
                .eq => return .{ mid, true },
                .gt => hi = mid,
            }
        }
        return .{ lo, false };
    }

    fn insert(t: *Tree, no: u32, item: Item, depth: usize) !Up {
        if (depth > 16) return error.Damaged;
        if (no != 0 and (try t.page(no))[0] == 2) {
            var b = try t.decodeBranch(no);
            // потомок: число ключей ≤ искомого
            var idx: usize = 0;
            while (idx < b.items.items.len and std.mem.order(u8, item.key, b.items.items[idx].key) != .lt) idx += 1;
            const child = if (idx == 0) b.first else b.items.items[idx - 1].child;
            const up = try t.insert(child, item, depth + 1);
            if (idx == 0) b.first = up.left else b.items.items[idx - 1].child = up.left;
            if (up.right != 0) try b.items.insert(idx, .{ .key = up.sep, .child = up.right });
            return t.writeBranch(no, b.first, b.items.items);
        }
        var items = try t.decodeLeaf(no);
        const at, const found = findItem(items.items, item.key);
        if (found) items.items[at] = item else try items.insert(at, item);
        return t.writeLeaf(no, items.items);
    }

    pub fn put(t: *Tree, key: []const u8, val: []const u8) !void {
        if (key.len == 0 or key.len > max_key) return error.KeyTooLong;
        try t.begin();
        const a = t.scratch.allocator();
        var item = Item{ .key = try a.dupe(u8, key), .vlen = @intCast(val.len) };
        if (val.len <= max_inline) {
            item.val = try a.dupe(u8, val);
        } else {
            // цепочка страниц, от хвоста к голове
            var next: u32 = 0;
            var end = val.len;
            while (end > 0) {
                const n = if (end % ovf_data == 0) ovf_data else end % ovf_data;
                const no, const pg = try t.newPage();
                pg[0] = 3;
                std.mem.writeInt(u32, pg[1..5], next, .little);
                std.mem.writeInt(u16, pg[5..7], @intCast(n), .little);
                @memcpy(pg[7..][0..n], val[end - n .. end]);
                next = no;
                end -= n;
            }
            item.ovf = next;
        }
        const up = try t.insert(t.root, item, 0);
        if (up.right == 0) {
            t.root = up.left;
        } else {
            const no, const pg = try t.newPage();
            encodeBranch(pg, up.left, &.{.{ .key = up.sep, .child = up.right }});
            t.root = no;
        }
    }

    fn remove(t: *Tree, no: u32, key: []const u8, depth: usize) !?u32 {
        if (depth > 16) return error.Damaged;
        if ((try t.page(no))[0] == 2) {
            var b = try t.decodeBranch(no);
            var idx: usize = 0;
            while (idx < b.items.items.len and std.mem.order(u8, key, b.items.items[idx].key) != .lt) idx += 1;
            const child = if (idx == 0) b.first else b.items.items[idx - 1].child;
            const new = try t.remove(child, key, depth + 1) orelse return null;
            if (idx == 0) b.first = new else b.items.items[idx - 1].child = new;
            return (try t.writeBranch(no, b.first, b.items.items)).left;
        }
        var items = try t.decodeLeaf(no);
        const at, const found = findItem(items.items, key);
        if (!found) return null;
        _ = items.orderedRemove(at);
        return (try t.writeLeaf(no, items.items)).left;
    }

    pub fn del(t: *Tree, key: []const u8) !void {
        try t.begin();
        if (t.root == 0) return;
        if (try t.remove(t.root, key, 0)) |r| t.root = r;
    }

    /// Сколько страниц достижимо из корня.
    pub fn live(t: *Tree) !u32 {
        if (t.root == 0) return 0;
        return t.liveFrom(t.root, 0);
    }

    fn liveFrom(t: *Tree, no: u32, depth: usize) !u32 {
        if (depth > 16) return error.Damaged;
        const pg = try t.page(no);
        var n: u32 = 1;
        if (pg[0] == 2) {
            var kids = std.ArrayList(u32).init(t.gpa);
            defer kids.deinit();
            var it = try BranchIt.init(pg);
            try kids.append(it.first());
            while (try it.next()) |x| try kids.append(x.child);
            for (kids.items) |k| n += try t.liveFrom(k, depth + 1);
        } else {
            var it = try LeafIt.init(pg);
            while (try it.next()) |x| {
                if (x.ovf != 0) n += @intCast((x.vlen + ovf_data - 1) / ovf_data);
            }
        }
        return n;
    }
};

/// Переписывает дерево в новый файл без мусора, если мусора в нём больше половины.
/// Зовётся при открытии, пока файл никто не читает.
pub fn compactIfNeeded(gpa: std.mem.Allocator, dir: std.fs.Dir) !void {
    var old = Tree.open(gpa, dir) catch return;
    const used = old.pages - 2;
    const alive = old.live() catch {
        old.close();
        return;
    };
    if (used < 256 or used < alive * 3) {
        old.close();
        return;
    }
    const tmp_name = file_name ++ ".new";
    dir.deleteFile(tmp_name) catch {};
    {
        defer old.close();
        var tmp_dir_file = try dir.createFile(tmp_name, .{ .read = true });
        tmp_dir_file.close();
        var fresh = try openNamed(gpa, dir, tmp_name);
        defer fresh.close();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var c = try old.seek("");
        var n: usize = 0;
        while (try c.next(arena.allocator())) |e| {
            try fresh.put(e.key, e.val);
            n += 1;
            if (n % 512 == 0) {
                try fresh.commit();
                _ = arena.reset(.retain_capacity);
            }
        }
        try fresh.commit();
    }
    try dir.rename(tmp_name, file_name);
}

fn openNamed(gpa: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !Tree {
    const file = try dir.createFile(name, .{ .read = true, .truncate = false });
    errdefer file.close();
    var t = Tree{
        .gpa = gpa,
        .file = file,
        .cache = try gpa.alloc(Page, cache_pages),
        .tags = try gpa.alloc(u32, cache_pages),
        .scratch = std.heap.ArenaAllocator.init(gpa),
    };
    @memset(t.tags, 0);
    var pg: Page = [_]u8{0} ** page_size;
    var m = Meta{};
    m.crc = m.sum();
    @memcpy(pg[0..@sizeOf(Meta)], std.mem.asBytes(&m));
    try file.pwriteAll(&pg, 0);
    try file.pwriteAll(&pg, page_size);
    _ = try t.refresh();
    return t;
}

test "дерево: вставка, поиск, обход, удаление, длинные значения" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    {
        var t = try Tree.open(gpa, tmp.dir);
        defer t.close();
        var kb: [32]u8 = undefined;
        var i: u32 = 0;
        while (i < 3000) : (i += 1) {
            const key = try std.fmt.bufPrint(&kb, "k{d:0>6}", .{(i * 7919) % 3000});
            const len: usize = if (i % 97 == 0) 9000 else rnd.uintLessThan(usize, 300);
            const val = try a.alloc(u8, len);
            @memset(val, @intCast('a' + i % 26));
            try t.put(key, val);
            if (i % 50 == 0) try t.commit();
        }
        try t.commit();
        try t.del("k000010");
        try t.commit();
    }
    var t = try Tree.open(gpa, tmp.dir);
    defer t.close();
    try std.testing.expect((try t.get(a, "k000010")) == null);
    try std.testing.expect((try t.get(a, "k000011")) != null);
    try std.testing.expectEqual(@as(usize, 9000), (try t.get(a, "k000000")).?.len);
    var c = try t.seek("k0001");
    var n: usize = 0;
    var prev: []const u8 = "";
    while (try c.next(a)) |e| {
        try std.testing.expect(std.mem.order(u8, prev, e.key) == .lt);
        prev = e.key;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2900), n);
}
