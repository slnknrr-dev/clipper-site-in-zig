//! Разбор Ogg Vorbis в отсчёты f32 (BACKLOG_RU.md §22) по спецификации Vorbis I:
//! страницы и пакеты Ogg, заголовки (идентификация, комментарии, настройка),
//! кодовые книги (дерево Хаффмана по правилу «наименьшего свободного кода»,
//! векторные таблицы 1 и 2), пол 1, остаток 0/1/2, отображение 0 с привязкой
//! каналов, ОМДКП (mdct.zig), окна и сложение с перекрытием. Конец обрезается по
//! granulepos последней страницы. Пол 0 (кодеры до 2001 года) не берётся.

const std = @import("std");
const Imdct = @import("mdct.zig").Imdct;

pub const Error = error{ NotVorbis, Unsupported, Damaged, OutOfMemory };

pub const max_ch = 8;

// ───────────── Ogg ─────────────

const Ogg = struct {
    data: []const u8,
    pos: usize = 0,
    serial: ?u32 = null,
    /// Сегменты текущей страницы
    seg: []const u8 = &.{},
    seg_i: usize = 0,
    body: usize = 0, // смещение тела страницы в data
    page_granule: i64 = -1,
    last_page: bool = false,
    pkt: std.ArrayList(u8),

    /// Следующий пакет потока (срез живёт до следующего вызова).
    fn next(o: *Ogg) ?[]const u8 {
        o.pkt.clearRetainingCapacity();
        while (true) {
            if (o.seg_i >= o.seg.len) {
                if (!o.page()) return if (o.pkt.items.len > 0) o.pkt.items else null;
                continue;
            }
            const l = o.seg[o.seg_i];
            o.seg_i += 1;
            const end = @min(o.body + l, o.data.len);
            o.pkt.appendSlice(o.data[o.body..end]) catch return null;
            o.body = end;
            if (l < 255) return o.pkt.items;
        }
    }

    fn page(o: *Ogg) bool {
        while (o.pos + 27 <= o.data.len) {
            const d = o.data[o.pos..];
            if (!std.mem.eql(u8, d[0..4], "OggS")) {
                // поиск следующей страницы
                const k = std.mem.indexOfPos(u8, o.data, o.pos + 1, "OggS") orelse return false;
                o.pos = k;
                continue;
            }
            const nseg = d[26];
            if (27 + @as(usize, nseg) > d.len) return false;
            const serial = std.mem.readInt(u32, d[14..18], .little);
            var body_len: usize = 0;
            for (d[27 .. 27 + nseg]) |s| body_len += s;
            const here = o.pos;
            o.pos += 27 + nseg + body_len;
            if (o.serial == null) o.serial = serial;
            if (serial != o.serial.?) continue; // другие логические потоки
            o.seg = d[27 .. 27 + nseg];
            o.seg_i = 0;
            o.body = here + 27 + nseg;
            o.page_granule = std.mem.readInt(i64, d[6..14], .little);
            o.last_page = d[5] & 4 != 0;
            return true;
        }
        return false;
    }
};

/// Последний granulepos потока (число отсчётов на канал), -1 — неизвестно.
fn lastGranule(data: []const u8, serial: u32) i64 {
    var p = data.len;
    while (p > 4) {
        const k = std.mem.lastIndexOf(u8, data[0..p], "OggS") orelse return -1;
        if (k + 27 <= data.len and std.mem.readInt(u32, data[k + 14 ..][0..4], .little) == serial) {
            const g = std.mem.readInt(i64, data[k + 6 ..][0..8], .little);
            if (g >= 0) return g;
        }
        p = k;
    }
    return -1;
}

// ───────────── чтение битов (младший бит первым) ─────────────

const Bits = struct {
    b: []const u8,
    pos: usize = 0,
    eop: bool = false,

    fn get(r: *Bits, n: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) v |= @as(u32, r.bit()) << @intCast(i);
        return v;
    }
    fn bit(r: *Bits) u1 {
        const byte = r.pos >> 3;
        if (byte >= r.b.len) {
            r.eop = true;
            return 0;
        }
        const v: u1 = @intCast((r.b[byte] >> @intCast(r.pos & 7)) & 1);
        r.pos += 1;
        return v;
    }
};

fn ilog(x: u32) u6 {
    return @intCast(32 - @clz(x));
}

fn unpackFloat(x: u32) f32 {
    const mant: f64 = @floatFromInt(x & 0x1fffff);
    const exp: i32 = @intCast((x & 0x7fe00000) >> 21);
    const v = std.math.ldexp(mant, exp - 788);
    return @floatCast(if (x & 0x80000000 != 0) -v else v);
}

fn lookup1Values(entries: u32, dims: u32) u32 {
    var r: u32 = @intFromFloat(@floor(std.math.pow(f64, @floatFromInt(entries), 1.0 / @as(f64, @floatFromInt(dims)))));
    // поправка на округление
    while (std.math.pow(f64, @floatFromInt(r + 1), @floatFromInt(dims)) <= @as(f64, @floatFromInt(entries))) r += 1;
    while (r > 0 and std.math.pow(f64, @floatFromInt(r), @floatFromInt(dims)) > @as(f64, @floatFromInt(entries))) r -= 1;
    return r;
}

// ───────────── кодовые книги ─────────────

const Book = struct {
    dims: u32,
    entries: u32,
    /// Дерево: узлы [2]i32; >= 0 — узел, < 0 — лист (-1 - запись).
    tree: [][2]i32,
    /// Значения векторов: entries × dims (пусто — книга только скалярная).
    vq: []f32,

    fn decode(b: *const Book, r: *Bits) ?u32 {
        if (b.tree.len == 0) return null;
        var at: i32 = 0;
        var guard: u32 = 0;
        while (guard < 40) : (guard += 1) {
            const nx = b.tree[@intCast(at)][r.bit()];
            if (r.eop) return null;
            if (nx < 0) return @intCast(-1 - nx);
            if (nx == 0) return null;
            at = nx;
        }
        return null;
    }

    fn vector(b: *const Book, r: *Bits) ?[]const f32 {
        const e = b.decode(r) orelse return null;
        if (b.vq.len == 0) return null;
        return b.vq[e * b.dims ..][0..b.dims];
    }
};

fn readBook(a: std.mem.Allocator, r: *Bits) Error!Book {
    if (r.get(24) != 0x564342) return error.Damaged;
    const dims = r.get(16);
    const entries = r.get(24);
    if (dims == 0 and entries > 0) return error.Damaged;
    const lens = try a.alloc(u8, entries);
    defer a.free(lens);
    if (r.get(1) == 0) {
        const sparse = r.get(1) == 1;
        for (lens) |*l| {
            if (sparse and r.get(1) == 0) {
                l.* = 0;
            } else l.* = @intCast(r.get(5) + 1);
        }
    } else {
        var cur: u32 = 0;
        var len: u32 = r.get(5) + 1;
        while (cur < entries) {
            const num = r.get(ilog(entries - cur));
            if (cur + num > entries or len > 32) return error.Damaged;
            @memset(lens[cur .. cur + num], @intCast(len));
            cur += num;
            len += 1;
        }
    }
    if (r.eop) return error.Damaged;
    const tree = try buildTree(a, lens);
    var vq: []f32 = &.{};
    const lt = r.get(4);
    if (lt == 1 or lt == 2) {
        const minv = unpackFloat(r.get(32));
        const delta = unpackFloat(r.get(32));
        const vbits: u6 = @intCast(r.get(4) + 1);
        const seq = r.get(1) == 1;
        const nvals: u32 = if (lt == 1) lookup1Values(entries, dims) else entries * dims;
        if (@as(u64, nvals) * vbits > r.b.len * 8) return error.Damaged;
        const mult = try a.alloc(u32, nvals);
        defer a.free(mult);
        for (mult) |*m| m.* = r.get(vbits);
        if (@as(u64, entries) * dims > 1 << 24) return error.Damaged;
        vq = try a.alloc(f32, entries * dims);
        for (0..entries) |e| {
            var last: f32 = 0;
            var div: u32 = 1;
            for (0..dims) |i| {
                const off = if (lt == 1) (@as(u32, @intCast(e)) / div) % nvals else @as(u32, @intCast(e)) * dims + @as(u32, @intCast(i));
                const v = @as(f32, @floatFromInt(mult[off])) * delta + minv + last;
                vq[e * dims + i] = v;
                if (seq) last = v;
                if (lt == 1) div *%= nvals;
            }
        }
    } else if (lt != 0) return error.Damaged;
    return .{ .dims = dims, .entries = entries, .tree = tree, .vq = vq };
}

/// Коды по правилу Vorbis: каждой записи — наименьший свободный код её длины.
fn buildTree(a: std.mem.Allocator, lens: []const u8) Error![][2]i32 {
    var nodes = std.ArrayList([2]i32).init(a);
    errdefer nodes.deinit();
    try nodes.append(.{ 0, 0 });
    var avail = [_]u32{0} ** 33;
    var first = true;
    var used: usize = 0;
    var only: usize = 0;
    for (lens, 0..) |l, i| {
        if (l == 0) continue;
        used += 1;
        only = i;
        var code: u32 = undefined;
        if (first) {
            first = false;
            code = 0;
            for (1..@as(usize, l) + 1) |k| avail[k] = @as(u32, 1) << @intCast(32 - k);
        } else {
            var z: usize = l;
            while (z > 0 and avail[z] == 0) z -= 1;
            if (z == 0) return error.Damaged;
            code = avail[z];
            avail[z] = 0;
            var y: usize = l;
            while (y > z) : (y -= 1) avail[y] = code + (@as(u32, 1) << @intCast(32 - y));
        }
        // вставка в дерево: биты от старшего
        var at: usize = 0;
        for (0..l) |k| {
            const b: usize = (code >> @intCast(31 - k)) & 1;
            if (k + 1 == l) {
                nodes.items[at][b] = -1 - @as(i32, @intCast(i));
            } else {
                if (nodes.items[at][b] == 0) {
                    try nodes.append(.{ 0, 0 });
                    nodes.items[at][b] = @intCast(nodes.items.len - 1);
                } else if (nodes.items[at][b] < 0) return error.Damaged;
                at = @intCast(nodes.items[at][b]);
            }
        }
    }
    if (used == 0) {
        nodes.deinit();
        return &.{};
    }
    if (used == 1) {
        // одна запись: любой бит — она
        nodes.items[0] = .{ -1 - @as(i32, @intCast(only)), -1 - @as(i32, @intCast(only)) };
    }
    return nodes.toOwnedSlice();
}

// ───────────── настройка ─────────────

const Floor1 = struct {
    partitions: u8,
    pclass: [32]u8,
    cdim: [16]u8,
    csub: [16]u8,
    cmaster: [16]u8,
    subbooks: [16][8]i16,
    mult: u8,
    x: [65]u16,
    values: usize,
    // сортировка и соседи
    order: [65]u8,
    low: [65]u8,
    high: [65]u8,
};

const Residue = struct {
    kind: u2,
    begin: u32,
    end: u32,
    psize: u32,
    classes: u32,
    classbook: u8,
    books: [64][8]i16,
};

const Mapping = struct {
    submaps: u8,
    steps: u16,
    mag: [256]u8,
    ang: [256]u8,
    mux: [max_ch]u8,
    floor: [16]u8,
    residue: [16]u8,
};

const Mode = struct { long: bool, mapping: u8 };

pub const Decoder = struct {
    arena: std.heap.ArenaAllocator,
    ogg: Ogg,
    rate: u32,
    channels: u8,
    bs: [2]usize,
    books: []Book,
    floors: []Floor1,
    residues: []Residue,
    maps: []Mapping,
    modes: []Mode,
    imdct: [2]Imdct,
    // состояние
    prev: [max_ch][]f32,
    prev_n: usize = 0,
    spec: [max_ch][]f32,
    out: [max_ch][]f32,
    win: [max_ch][]f32,
    total: u64 = 0,
    end_granule: i64,
    first_audio: bool = true,
    /// Сколько отсчётов отбросить в начале (по granulepos первой страницы звука).
    skip: usize = 0,

    pub fn init(gpa: std.mem.Allocator, data: []const u8) Error!*Decoder {
        const d = try gpa.create(Decoder);
        errdefer gpa.destroy(d);
        d.arena = std.heap.ArenaAllocator.init(gpa);
        d.prev_n = 0;
        d.total = 0;
        d.first_audio = true;
        d.skip = 0;
        errdefer d.arena.deinit();
        const a = d.arena.allocator();
        d.ogg = .{ .data = data, .pkt = std.ArrayList(u8).init(a) };
        // идентификация
        const id = d.ogg.next() orelse return error.NotVorbis;
        if (id.len < 30 or id[0] != 1 or !std.mem.eql(u8, id[1..7], "vorbis")) return error.NotVorbis;
        d.channels = id[11];
        d.rate = std.mem.readInt(u32, id[12..16], .little);
        d.bs = .{ @as(usize, 1) << @intCast(id[28] & 15), @as(usize, 1) << @intCast(id[28] >> 4) };
        if (d.channels == 0 or d.channels > max_ch or d.rate == 0 or d.bs[0] < 64 or d.bs[1] > 8192 or d.bs[0] > d.bs[1]) return error.Unsupported;
        d.end_granule = lastGranule(data, d.ogg.serial.?);
        // комментарии
        const cm = d.ogg.next() orelse return error.Damaged;
        if (cm.len < 7 or cm[0] != 3) return error.Damaged;
        // настройка
        const setup = try a.dupe(u8, d.ogg.next() orelse return error.Damaged);
        if (setup.len < 7 or setup[0] != 5 or !std.mem.eql(u8, setup[1..7], "vorbis")) return error.Damaged;
        try d.readSetup(a, setup[7..]);
        d.skip = d.startSkip(a, data);
        for (0..2) |k| d.imdct[k] = try Imdct.init(a, d.bs[k] / 2);
        for (0..d.channels) |c| {
            d.prev[c] = try a.alloc(f32, d.bs[1]);
            d.spec[c] = try a.alloc(f32, d.bs[1] / 2);
            d.out[c] = try a.alloc(f32, d.bs[1]);
            d.win[c] = try a.alloc(f32, d.bs[1]);
        }
        return d;
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        d.arena.deinit();
        gpa.destroy(d);
    }

    fn readSetup(d: *Decoder, a: std.mem.Allocator, b: []const u8) Error!void {
        var r = Bits{ .b = b };
        const nb = r.get(8) + 1;
        d.books = try a.alloc(Book, nb);
        for (d.books) |*bk| bk.* = try readBook(a, &r);
        const nt = r.get(6) + 1;
        for (0..nt) |_| if (r.get(16) != 0) return error.Damaged;
        const nf = r.get(6) + 1;
        d.floors = try a.alloc(Floor1, nf);
        for (d.floors) |*f| {
            const t = r.get(16);
            if (t != 1) return error.Unsupported; // пол 0
            f.partitions = @intCast(r.get(5));
            var maxc: u32 = 0;
            for (0..f.partitions) |p| {
                f.pclass[p] = @intCast(r.get(4));
                maxc = @max(maxc, f.pclass[p] + 1);
            }
            for (0..maxc) |c| {
                f.cdim[c] = @intCast(r.get(3) + 1);
                f.csub[c] = @intCast(r.get(2));
                f.cmaster[c] = if (f.csub[c] > 0) @intCast(r.get(8)) else 0;
                if (f.csub[c] > 0 and f.cmaster[c] >= nb) return error.Damaged;
                for (0..@as(usize, 1) << @intCast(f.csub[c])) |j| {
                    const sb: i16 = @as(i16, @intCast(r.get(8))) - 1;
                    if (sb >= @as(i16, @intCast(nb))) return error.Damaged;
                    f.subbooks[c][j] = sb;
                }
            }
            f.mult = @intCast(r.get(2) + 1);
            const rb: u6 = @intCast(r.get(4));
            f.x[0] = 0;
            f.x[1] = @intCast(@as(u32, 1) << @as(u5, @intCast(rb)));
            f.values = 2;
            for (0..f.partitions) |p| {
                const c = f.pclass[p];
                for (0..f.cdim[c]) |_| {
                    if (f.values >= 65) return error.Damaged;
                    f.x[f.values] = @intCast(r.get(rb));
                    f.values += 1;
                }
            }
            // порядок по X и соседи
            for (0..f.values) |i| f.order[i] = @intCast(i);
            std.mem.sort(u8, f.order[0..f.values], f, struct {
                fn lt(ff: *Floor1, x: u8, y: u8) bool {
                    return ff.x[x] < ff.x[y];
                }
            }.lt);
            for (2..f.values) |i| {
                var lo: usize = 0;
                var hi: usize = 1;
                var lx: i32 = -1;
                var hx: i32 = 1 << 20;
                for (0..i) |j| {
                    const xj: i32 = f.x[j];
                    if (xj < f.x[i] and xj > lx) {
                        lx = xj;
                        lo = j;
                    }
                    if (xj > f.x[i] and xj < hx) {
                        hx = xj;
                        hi = j;
                    }
                }
                f.low[i] = @intCast(lo);
                f.high[i] = @intCast(hi);
            }
        }
        const nr = r.get(6) + 1;
        d.residues = try a.alloc(Residue, nr);
        for (d.residues) |*res| {
            const t = r.get(16);
            if (t > 2) return error.Damaged;
            res.kind = @intCast(t);
            res.begin = r.get(24);
            res.end = r.get(24);
            res.psize = r.get(24) + 1;
            res.classes = r.get(6) + 1;
            res.classbook = @intCast(r.get(8));
            if (res.classbook >= nb) return error.Damaged;
            var casc: [64]u32 = undefined;
            for (0..res.classes) |i| {
                const low = r.get(3);
                const high = if (r.get(1) == 1) r.get(5) else 0;
                casc[i] = high * 8 + low;
            }
            for (0..res.classes) |i| for (0..8) |j| {
                res.books[i][j] = if (casc[i] & (@as(u32, 1) << @intCast(j)) != 0) blk: {
                    const bk = r.get(8);
                    if (bk >= nb) return error.Damaged;
                    break :blk @intCast(bk);
                } else -1;
            };
        }
        const nm = r.get(6) + 1;
        d.maps = try a.alloc(Mapping, nm);
        for (d.maps) |*m| {
            if (r.get(16) != 0) return error.Damaged;
            m.submaps = if (r.get(1) == 1) @intCast(r.get(4) + 1) else 1;
            m.steps = 0;
            if (r.get(1) == 1) {
                m.steps = @intCast(r.get(8) + 1);
                const bits = ilog(d.channels - 1);
                for (0..m.steps) |s| {
                    m.mag[s] = @intCast(r.get(bits));
                    m.ang[s] = @intCast(r.get(bits));
                    if (m.mag[s] >= d.channels or m.ang[s] >= d.channels or m.mag[s] == m.ang[s]) return error.Damaged;
                }
            }
            if (r.get(2) != 0) return error.Damaged;
            @memset(&m.mux, 0);
            if (m.submaps > 1) for (0..d.channels) |c| {
                m.mux[c] = @intCast(r.get(4));
                if (m.mux[c] >= m.submaps) return error.Damaged;
            };
            for (0..m.submaps) |s| {
                _ = r.get(8);
                m.floor[s] = @intCast(r.get(8));
                m.residue[s] = @intCast(r.get(8));
                if (m.floor[s] >= nf or m.residue[s] >= nr) return error.Damaged;
            }
        }
        const nmo = r.get(6) + 1;
        d.modes = try a.alloc(Mode, nmo);
        for (d.modes) |*mo| {
            mo.long = r.get(1) == 1;
            if (r.get(16) != 0 or r.get(16) != 0) return error.Damaged;
            mo.mapping = @intCast(r.get(8));
            if (mo.mapping >= nm) return error.Damaged;
        }
        if (r.get(1) != 1 or r.eop) return error.Damaged;
    }

    /// Следующая порция: отсчёты по каналам в out[c][0..n]; 0 — конец.
    pub fn next(d: *Decoder) usize {
        while (true) {
            const pkt = d.ogg.next() orelse return 0;
            var n = d.audio(pkt) catch continue;
            if (d.skip > 0) {
                const drop = @min(d.skip, n);
                for (0..d.channels) |c| std.mem.copyForwards(f32, d.out[c][0 .. n - drop], d.out[c][drop..n]);
                n -= drop;
                d.skip -= drop;
            }
            if (n == 0) continue;
            if (d.end_granule >= 0 and d.total + n > @as(u64, @intCast(d.end_granule))) {
                n = @intCast(@as(u64, @intCast(d.end_granule)) -| d.total);
                if (n == 0) return 0;
            }
            d.total += n;
            return n;
        }
    }

    /// Лишнее в начале: сколько отсчётов дают пакеты первой страницы звука сверх
    /// её granulepos (так обрезают libvorbisfile и ffmpeg).
    fn startSkip(d: *Decoder, a: std.mem.Allocator, data: []const u8) usize {
        var o = Ogg{ .data = data, .pkt = std.ArrayList(u8).init(a) };
        defer o.pkt.deinit();
        for (0..3) |_| _ = o.next() orelse return 0;
        var sum: u64 = 0;
        var pn: usize = 0;
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            const pkt = o.next() orelse return 0;
            if (pkt.len == 0 or pkt[0] & 1 != 0) continue;
            var r = Bits{ .b = pkt };
            _ = r.get(1);
            const mi = r.get(ilog(@intCast(d.modes.len - 1)));
            if (mi >= d.modes.len) continue;
            const n = d.bs[@intFromBool(d.modes[mi].long)];
            if (pn != 0) sum += pn / 4 + n / 4;
            pn = n;
            // последний пакет, завершённый на этой странице?
            var more = false;
            for (o.seg[o.seg_i..]) |l| more = more or l < 255;
            if (!more and o.page_granule >= 0) {
                const g: u64 = @intCast(o.page_granule);
                return if (sum > g and !o.last_page) @intCast(sum - g) else 0;
            }
        }
        return 0;
    }

    fn audio(d: *Decoder, pkt: []const u8) Error!usize {
        var r = Bits{ .b = pkt };
        if (r.get(1) != 0) return error.Damaged;
        const mode = d.modes[r.get(ilog(@intCast(d.modes.len - 1)))];
        const long = mode.long;
        const n = d.bs[@intFromBool(long)];
        var prev_long = false;
        var next_long = false;
        if (long) {
            prev_long = r.get(1) == 1;
            next_long = r.get(1) == 1;
        }
        if (r.eop) return error.Damaged;
        const m = &d.maps[mode.mapping];
        const h = n / 2;
        // пол
        var floor_y: [max_ch][65]i32 = undefined;
        var used: [max_ch]bool = .{false} ** max_ch;
        for (0..d.channels) |c| {
            const f = &d.floors[m.floor[m.mux[c]]];
            used[c] = d.readFloor(f, &r, &floor_y[c]);
        }
        // привязанные каналы: ненулевой хотя бы один — декодируются оба
        var no_res: [max_ch]bool = undefined;
        for (0..d.channels) |c| no_res[c] = !used[c];
        for (0..m.steps) |s| {
            if (!no_res[m.mag[s]] or !no_res[m.ang[s]]) {
                no_res[m.mag[s]] = false;
                no_res[m.ang[s]] = false;
            }
        }
        // остаток по подкартам
        for (0..d.channels) |c| @memset(d.spec[c][0..h], 0);
        for (0..m.submaps) |s| {
            var chs: [max_ch]usize = undefined;
            var nch: usize = 0;
            for (0..d.channels) |c| if (m.mux[c] == s) {
                chs[nch] = c;
                nch += 1;
            };
            d.readResidue(&d.residues[m.residue[s]], &r, chs[0..nch], &no_res, h);
        }
        // обратная привязка
        var s = m.steps;
        while (s > 0) {
            s -= 1;
            const mg = d.spec[m.mag[s]];
            const an = d.spec[m.ang[s]];
            for (0..h) |i| {
                const M = mg[i];
                const A = an[i];
                if (M > 0) {
                    if (A > 0) {
                        an[i] = M - A;
                    } else {
                        an[i] = M;
                        mg[i] = M + A;
                    }
                } else {
                    if (A > 0) {
                        an[i] = M + A;
                    } else {
                        an[i] = M;
                        mg[i] = M - A;
                    }
                }
            }
        }
        // пол × остаток, ОМДКП, окно
        var curve: [4096]i32 = undefined;
        for (0..d.channels) |c| {
            const cur = d.win[c][0..n];
            if (!used[c]) {
                @memset(cur, 0);
            } else {
                const f = &d.floors[m.floor[m.mux[c]]];
                renderFloor(f, &floor_y[c], curve[0..h]);
                for (0..h) |i| d.spec[c][i] *= floor_db[@intCast(std.math.clamp(curve[i], 0, 255))];
                d.imdct[@intFromBool(long)].run(d.spec[c][0..h], cur);
            }
            d.window(cur, long, prev_long, next_long);
        }
        // сложение с перекрытием: от центра прошлого окна до центра текущего
        defer d.prev_n = n;
        defer for (0..d.channels) |c| @memcpy(d.prev[c][0..n], d.win[c][0..n]);
        if (d.first_audio) {
            d.first_audio = false;
            return 0;
        }
        const pn = d.prev_n;
        const count = pn / 4 + n / 4;
        for (0..d.channels) |c| {
            const pv = d.prev[c];
            const cur = d.win[c];
            for (0..count) |i| {
                const p = pn / 2 + i;
                const ci: isize = @as(isize, @intCast(i + n / 4)) - @as(isize, @intCast(pn / 4));
                var v: f32 = if (p < pn) pv[p] else 0;
                if (ci >= 0 and ci < n) v += cur[@intCast(ci)];
                d.out[c][i] = v;
            }
        }
        return count;
    }

    fn window(d: *Decoder, v: []f32, long: bool, prev_long: bool, next_long: bool) void {
        const n = v.len;
        const s0 = d.bs[0];
        var ls: usize = 0;
        var le: usize = n / 2;
        var rs: usize = n / 2;
        var re: usize = n;
        if (long and !prev_long) {
            ls = n / 4 - s0 / 4;
            le = n / 4 + s0 / 4;
        }
        if (long and !next_long) {
            rs = n * 3 / 4 - s0 / 4;
            re = n * 3 / 4 + s0 / 4;
        }
        const ln: f32 = @floatFromInt(le - ls);
        const rn: f32 = @floatFromInt(re - rs);
        for (0..n) |i| {
            var w: f32 = 1;
            if (i < ls or i >= re) {
                w = 0;
            } else if (i < le) {
                const t = (@as(f32, @floatFromInt(i - ls)) + 0.5) / ln * std.math.pi / 2.0;
                w = @sin(std.math.pi / 2.0 * @sin(t) * @sin(t));
            } else if (i >= rs) {
                const t = (@as(f32, @floatFromInt(i - rs)) + 0.5) / rn * std.math.pi / 2.0 + std.math.pi / 2.0;
                w = @sin(std.math.pi / 2.0 * @sin(t) * @sin(t));
            }
            v[i] *= w;
        }
    }

    fn readFloor(d: *Decoder, f: *const Floor1, r: *Bits, y: *[65]i32) bool {
        if (r.get(1) == 0) return false;
        const range = [4]u32{ 256, 128, 86, 64 };
        const rbits = ilog(range[f.mult - 1] - 1);
        y[0] = @intCast(r.get(rbits));
        y[1] = @intCast(r.get(rbits));
        var off: usize = 2;
        for (0..f.partitions) |p| {
            const c = f.pclass[p];
            const cdim = f.cdim[c];
            const cbits: u5 = @intCast(f.csub[c]);
            const csub = (@as(u32, 1) << cbits) - 1;
            var cval: u32 = 0;
            if (cbits > 0) cval = d.books[f.cmaster[c]].decode(r) orelse return false;
            for (0..cdim) |_| {
                const book = f.subbooks[c][cval & csub];
                cval >>= cbits;
                y[off] = if (book >= 0) @intCast(d.books[@intCast(book)].decode(r) orelse return false) else 0;
                off += 1;
            }
        }
        return !r.eop;
    }

    fn readResidue(d: *Decoder, res: *const Residue, r: *Bits, chs: []const usize, no_res: *const [max_ch]bool, h: usize) void {
        if (chs.len == 0) return;
        const cb = &d.books[res.classbook];
        if (res.kind == 2) {
            var any = false;
            for (chs) |c| any = any or !no_res[c];
            if (!any) return;
            const total = h * chs.len;
            const big = d.arena.allocator().alloc(f32, total) catch return;
            defer d.arena.allocator().free(big);
            @memset(big, 0);
            var vecs = [_][]f32{big};
            var dnd = [_]bool{false};
            d.residueCore(res, cb, r, &vecs, &dnd, total, 1);
            for (0..h) |i| for (chs, 0..) |c, j| {
                d.spec[c][i] = big[i * chs.len + j];
            };
            return;
        }
        var vecs: [max_ch][]f32 = undefined;
        var dnd: [max_ch]bool = undefined;
        for (chs, 0..) |c, j| {
            vecs[j] = d.spec[c][0..h];
            dnd[j] = no_res[c];
        }
        d.residueCore(res, cb, r, vecs[0..chs.len], dnd[0..chs.len], h, res.kind);
    }

    fn residueCore(d: *Decoder, res: *const Residue, cb: *const Book, r: *Bits, vecs: [][]f32, dnd: []const bool, size: usize, kind: u2) void {
        const lb = @min(res.begin, size);
        const le = @min(res.end, size);
        if (le <= lb) return;
        const psize = res.psize;
        const nparts = (le - lb) / psize;
        if (nparts == 0) return;
        const cpw = cb.dims;
        if (cpw == 0) return;
        const cls = d.arena.allocator().alloc(u8, vecs.len * (nparts + cpw)) catch return;
        defer d.arena.allocator().free(cls);
        for (0..8) |pass| {
            var pc: usize = 0;
            while (pc < nparts) {
                if (pass == 0) {
                    for (vecs, 0..) |_, j| {
                        if (dnd[j]) continue;
                        var t = cb.decode(r) orelse return;
                        var i: usize = cpw;
                        while (i > 0) {
                            i -= 1;
                            cls[j * (nparts + cpw) + pc + i] = @intCast(t % res.classes);
                            t /= res.classes;
                        }
                    }
                }
                var i: usize = 0;
                while (i < cpw and pc < nparts) : (i += 1) {
                    for (vecs, 0..) |v, j| {
                        if (dnd[j]) continue;
                        const c = cls[j * (nparts + cpw) + pc];
                        const bk = res.books[c][pass];
                        if (bk < 0) continue;
                        const book = &d.books[@intCast(bk)];
                        const off = lb + pc * psize;
                        if (book.dims == 0) continue;
                        if (kind == 0) {
                            const step = psize / book.dims;
                            for (0..step) |s| {
                                const e = book.vector(r) orelse return;
                                for (0..book.dims) |k| v[off + s + k * step] += e[k];
                            }
                        } else {
                            var s: usize = 0;
                            while (s < psize) {
                                const e = book.vector(r) orelse return;
                                for (0..book.dims) |k| {
                                    if (s < psize) v[off + s] += e[k];
                                    s += 1;
                                }
                            }
                        }
                    }
                    pc += 1;
                }
            }
        }
    }
};

fn renderPoint(x0: i32, y0: i32, x1: i32, y1: i32, x: i32) i32 {
    const dy = y1 - y0;
    const adx = x1 - x0;
    const ady: i32 = @intCast(@abs(dy));
    const err = ady * (x - x0);
    const off = @divTrunc(err, adx);
    return if (dy < 0) y0 - off else y0 + off;
}

fn renderLine(x0: i32, y0: i32, x1: i32, y1: i32, v: []i32) void {
    const dy = y1 - y0;
    const adx = x1 - x0;
    var ady: i32 = @intCast(@abs(dy));
    const base = @divTrunc(dy, adx);
    var x = x0;
    var y = y0;
    var err: i32 = 0;
    const sy = if (dy < 0) base - 1 else base + 1;
    ady -= @as(i32, @intCast(@abs(base))) * adx;
    if (x >= v.len) return;
    v[@intCast(x)] = y;
    x += 1;
    while (x < x1) : (x += 1) {
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else y += base;
        if (x >= v.len) return;
        v[@intCast(x)] = y;
    }
}

fn renderFloor(f: *const Floor1, yv: *const [65]i32, out: []i32) void {
    const range = [4]i32{ 256, 128, 86, 64 };
    const rng = range[f.mult - 1];
    var fy: [65]i32 = undefined;
    var step2: [65]bool = undefined;
    step2[0] = true;
    step2[1] = true;
    fy[0] = yv[0];
    fy[1] = yv[1];
    for (2..f.values) |i| {
        const lo = f.low[i];
        const hi = f.high[i];
        const pred = renderPoint(f.x[lo], fy[lo], f.x[hi], fy[hi], f.x[i]);
        const val = yv[i];
        const hroom = rng - pred;
        const lroom = pred;
        const room = if (hroom < lroom) hroom * 2 else lroom * 2;
        if (val != 0) {
            step2[lo] = true;
            step2[hi] = true;
            step2[i] = true;
            if (val >= room) {
                fy[i] = if (hroom > lroom) val - lroom + pred else pred - val + hroom - 1;
            } else {
                fy[i] = if (val & 1 == 1) pred - @divTrunc(val + 1, 2) else pred + @divTrunc(val, 2);
            }
        } else {
            step2[i] = false;
            fy[i] = pred;
        }
        fy[i] = std.math.clamp(fy[i], 0, rng - 1);
    }
    const n: i32 = @intCast(out.len);
    var hx: i32 = 0;
    var hy: i32 = 0;
    var lx: i32 = 0;
    var ly: i32 = fy[f.order[0]] * f.mult;
    for (1..f.values) |k| {
        const i = f.order[k];
        if (!step2[i]) continue;
        hy = fy[i] * f.mult;
        hx = f.x[i];
        if (hx > lx) renderLine(lx, ly, hx, hy, out);
        lx = hx;
        ly = hy;
    }
    if (hx < n) renderLine(hx, hy, n, hy, out);
}

/// floor1_inverse_dB_table: 10^(7·(i−255)/256), от 1.0649863e-07 до 1.
const floor_db = blk: {
    @setEvalBranchQuota(200000);
    var t: [256]f32 = undefined;
    for (0..256) |i| t[i] = @floatCast(@exp(std.math.ln10 * 7.0 * (@as(f64, @floatFromInt(i)) - 255.0) / 256.0));
    break :blk t;
};

test "vorbis: дерево кодов по правилу наименьшего свободного" {
    const a = std.testing.allocator;
    // пример из спецификации: длины 2,4,4,4,4,2,3,3
    const t = try buildTree(a, &.{ 2, 4, 4, 4, 4, 2, 3, 3 });
    defer a.free(t);
    // коды: 00, 0100, 0101, 0110, 0111, 10, 110, 111
    var r = Bits{ .b = &.{0b01} }; // код 10: биты младшим вперёд — 1, 0
    var bk = Book{ .dims = 1, .entries = 8, .tree = t, .vq = &.{} };
    try std.testing.expectEqual(@as(?u32, 5), bk.decode(&r));
    _ = &bk;
}
