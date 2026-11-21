//! Разбор M4A (MP4 с AAC) в отсчёты f32 (BACKLOG_RU.md §22).
//!
//! Контейнер: moov/trak (звуковая дорожка) → stsd/mp4a/esds (AudioSpecificConfig),
//! stsz, stsc, stco/co64 — где лежит каждый кадр; elst — сколько отсчётов
//! отбросить в начале (задержка кодера) и сколько всего.
//! Кодек: AAC LC — элементы SCE, CPE, LFE, DSE, PCE, FIL; ics_info, секции,
//! множители масштаба, импульсы, TNS, спектр (11 книг, ESC), M/S, интенсивное
//! стерео, PNS; банк фильтров: ОМДКП (mdct.zig), окна синус и KBD, все четыре
//! последовательности окон. HE-AAC (SBR/PS) декодируется только ядром LC — на
//! половинной частоте, без верхних полос. Main, SSR, LTP и CCE не берутся.

const std = @import("std");
const tab = @import("aactab.zig");
const Imdct = @import("mdct.zig").Imdct;

pub const Error = error{ NotM4a, Unsupported, Damaged, OutOfMemory };

pub const max_ch = 8;

// ───────────── MP4 ─────────────

const Box = struct { kind: [4]u8, body: []const u8 };

fn boxes(b: []const u8, at: *usize) ?Box {
    if (at.* + 8 > b.len) return null;
    const d = b[at.*..];
    var size: u64 = std.mem.readInt(u32, d[0..4], .big);
    var hdr: usize = 8;
    if (size == 1) {
        if (d.len < 16) return null;
        size = std.mem.readInt(u64, d[8..16], .big);
        hdr = 16;
    } else if (size == 0) size = d.len;
    if (size < hdr or size > d.len) return null;
    at.* += @intCast(size);
    return .{ .kind = d[4..8].*, .body = d[hdr..@intCast(size)] };
}

fn find(b: []const u8, kind: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (boxes(b, &at)) |x| if (std.mem.eql(u8, &x.kind, kind)) return x.body;
    return null;
}

const Track = struct {
    asc: []const u8,
    sizes: []u32,
    offsets: []u64,
    channels: u16,
    media_scale: u32,
    movie_scale: u32,
    skip: u64 = 0,
    duration: u64 = 0, // в отсчётах; 0 — неизвестно
};

fn readTrack(a: std.mem.Allocator, data: []const u8) Error!Track {
    const moov = find(data, "moov") orelse return error.NotM4a;
    var movie_scale: u32 = 1000;
    if (find(moov, "mvhd")) |mv| {
        if (mv.len >= 20) movie_scale = if (mv[0] == 1) std.mem.readInt(u32, mv[20..24], .big) else std.mem.readInt(u32, mv[12..16], .big);
    }
    var at: usize = 0;
    while (boxes(moov, &at)) |trak| {
        if (!std.mem.eql(u8, &trak.kind, "trak")) continue;
        const mdia = find(trak.body, "mdia") orelse continue;
        const hdlr = find(mdia, "hdlr") orelse continue;
        if (hdlr.len < 12 or !std.mem.eql(u8, hdlr[8..12], "soun")) continue;
        const mdhd = find(mdia, "mdhd") orelse return error.Damaged;
        const media_scale = if (mdhd.len >= 24 and mdhd[0] == 1) std.mem.readInt(u32, mdhd[20..24], .big) else if (mdhd.len >= 16) std.mem.readInt(u32, mdhd[12..16], .big) else return error.Damaged;
        const minf = find(mdia, "minf") orelse return error.Damaged;
        const stbl = find(minf, "stbl") orelse return error.Damaged;
        const stsd = find(stbl, "stsd") orelse return error.Damaged;
        if (stsd.len < 8 + 36) return error.Damaged;
        var sat: usize = 8;
        const entry = boxes(stsd, &sat) orelse return error.Damaged;
        if (!std.mem.eql(u8, &entry.kind, "mp4a")) return error.Unsupported;
        if (entry.body.len < 28) return error.Damaged;
        const channels = std.mem.readInt(u16, entry.body[16..18], .big);
        const esds = find(entry.body[28..], "esds") orelse return error.Damaged;
        const asc = descriptor(esds[4..]) orelse return error.Damaged;
        var t = Track{ .asc = asc, .sizes = &.{}, .offsets = &.{}, .channels = channels, .media_scale = media_scale, .movie_scale = movie_scale };
        // размеры
        const stsz = find(stbl, "stsz") orelse return error.Damaged;
        if (stsz.len < 12) return error.Damaged;
        const fixed = std.mem.readInt(u32, stsz[4..8], .big);
        const count = std.mem.readInt(u32, stsz[8..12], .big);
        if (count > 50_000_000) return error.Damaged;
        t.sizes = try a.alloc(u32, count);
        for (t.sizes, 0..) |*s, i| {
            if (fixed != 0) {
                s.* = fixed;
            } else {
                if (12 + 4 * i + 4 > stsz.len) return error.Damaged;
                s.* = std.mem.readInt(u32, stsz[12 + 4 * i ..][0..4], .big);
            }
        }
        // куски
        var chunks: []u64 = &.{};
        if (find(stbl, "stco")) |stco| {
            const n = std.mem.readInt(u32, stco[4..8], .big);
            if (8 + 4 * @as(usize, n) > stco.len) return error.Damaged;
            chunks = try a.alloc(u64, n);
            for (chunks, 0..) |*c, i| c.* = std.mem.readInt(u32, stco[8 + 4 * i ..][0..4], .big);
        } else if (find(stbl, "co64")) |co| {
            const n = std.mem.readInt(u32, co[4..8], .big);
            if (8 + 8 * @as(usize, n) > co.len) return error.Damaged;
            chunks = try a.alloc(u64, n);
            for (chunks, 0..) |*c, i| c.* = std.mem.readInt(u64, co[8 + 8 * i ..][0..8], .big);
        } else return error.Damaged;
        const stsc = find(stbl, "stsc") orelse return error.Damaged;
        const ne = std.mem.readInt(u32, stsc[4..8], .big);
        if (8 + 12 * @as(usize, ne) > stsc.len or ne == 0) return error.Damaged;
        t.offsets = try a.alloc(u64, count);
        var si: usize = 0;
        for (0..ne) |e| {
            const first = std.mem.readInt(u32, stsc[8 + 12 * e ..][0..4], .big);
            const per = std.mem.readInt(u32, stsc[12 + 12 * e ..][0..4], .big);
            const next_first: usize = if (e + 1 < ne) std.mem.readInt(u32, stsc[8 + 12 * (e + 1) ..][0..4], .big) else chunks.len + 1;
            if (first == 0) return error.Damaged;
            var ch: usize = first;
            while (ch < next_first and ch <= chunks.len) : (ch += 1) {
                var off = chunks[ch - 1];
                for (0..per) |_| {
                    if (si >= count) break;
                    t.offsets[si] = off;
                    off += t.sizes[si];
                    si += 1;
                }
            }
        }
        if (si < count) t.sizes = t.sizes[0..si];
        // правка (elst): начало и длительность
        if (find(trak.body, "edts")) |edts| if (find(edts, "elst")) |el| {
            if (el.len >= 8 and std.mem.readInt(u32, el[4..8], .big) >= 1) {
                if (el[0] == 1 and el.len >= 8 + 20) {
                    const dur = std.mem.readInt(u64, el[8..16], .big);
                    const mt = std.mem.readInt(i64, el[16..24], .big);
                    if (mt > 0) t.skip = @intCast(mt);
                    t.duration = dur * media_scale / @max(movie_scale, 1);
                } else if (el.len >= 8 + 12) {
                    const dur = std.mem.readInt(u32, el[8..12], .big);
                    const mt = std.mem.readInt(i32, el[12..16], .big);
                    if (mt > 0) t.skip = @intCast(mt);
                    t.duration = @as(u64, dur) * media_scale / @max(movie_scale, 1);
                }
            }
        };
        if (t.skip == 0 and t.duration == 0) itunSmpb(moov, &t);
        return t;
    }
    return error.NotM4a;
}

/// Тег iTunes «iTunSMPB»: « 00000000 ЗАДЕРЖКА ХВОСТ ДЛИНА …» шестнадцатеричными.
fn itunSmpb(moov: []const u8, t: *Track) void {
    const k = std.mem.indexOf(u8, moov, "iTunSMPB") orelse return;
    const dk = std.mem.indexOfPos(u8, moov, k, "data") orelse return;
    if (dk + 12 > moov.len) return;
    const end = @min(moov.len, dk + 12 + 120);
    var it = std.mem.tokenizeScalar(u8, moov[dk + 12 .. end], ' ');
    _ = it.next() orelse return;
    const pre = std.fmt.parseInt(u64, it.next() orelse return, 16) catch return;
    _ = it.next() orelse return;
    const len_s = it.next() orelse return;
    const len = std.fmt.parseInt(u64, len_s[0..@min(len_s.len, 16)], 16) catch return;
    if (pre > 1 << 20) return;
    t.skip = pre;
    t.duration = len;
}

/// ES_Descriptor → DecoderSpecificInfo (AudioSpecificConfig).
fn descriptor(b: []const u8) ?[]const u8 {
    var p: usize = 0;
    const Desc = struct { tag: u8, body: []const u8 };
    const read = struct {
        fn f(d: []const u8, at: *usize) ?Desc {
            if (at.* >= d.len) return null;
            const tag = d[at.*];
            at.* += 1;
            var len: usize = 0;
            for (0..4) |_| {
                if (at.* >= d.len) return null;
                const c = d[at.*];
                at.* += 1;
                len = (len << 7) | (c & 0x7F);
                if (c & 0x80 == 0) break;
            }
            if (at.* + len > d.len) return null;
            defer at.* += len;
            return .{ .tag = tag, .body = d[at.* .. at.* + len] };
        }
    }.f;
    const es = read(b, &p) orelse return null;
    if (es.tag != 3 or es.body.len < 3) return null;
    var q: usize = 3;
    const flags = es.body[2];
    if (flags & 0x80 != 0) q += 2;
    if (flags & 0x40 != 0) {
        if (q >= es.body.len) return null;
        q += 1 + es.body[q];
    }
    if (flags & 0x20 != 0) q += 2;
    while (read(es.body, &q)) |dc| {
        if (dc.tag != 4 or dc.body.len < 13) continue;
        var r: usize = 13;
        while (read(dc.body, &r)) |ds| if (ds.tag == 5) return ds.body;
    }
    return null;
}

// ───────────── биты (старший первым) ─────────────

const Bits = struct {
    b: []const u8,
    pos: usize = 0,

    fn get(r: *Bits, n: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) v = (v << 1) | r.bit();
        return v;
    }
    fn bit(r: *Bits) u32 {
        const byte = r.pos >> 3;
        const v: u32 = if (byte < r.b.len) (r.b[byte] >> @intCast(7 - (r.pos & 7))) & 1 else 0;
        r.pos += 1;
        return v;
    }
    fn over(r: *const Bits) bool {
        return r.pos > r.b.len * 8;
    }
};

// ───────────── Хаффман ─────────────

const Tree = struct {
    node: [][2]i16,
    fn build(a: std.mem.Allocator, h: tab.Huff) !Tree {
        var nodes = std.ArrayList([2]i16).init(a);
        try nodes.append(.{ 0, 0 });
        for (h.codes, h.lens, 0..) |code, len, sym| {
            var at: usize = 0;
            var k: u5 = @intCast(len);
            while (k > 0) {
                k -= 1;
                const b: usize = (code >> k) & 1;
                if (k == 0) {
                    nodes.items[at][b] = -1 - @as(i16, @intCast(sym));
                } else {
                    if (nodes.items[at][b] == 0) {
                        try nodes.append(.{ 0, 0 });
                        nodes.items[at][b] = @intCast(nodes.items.len - 1);
                    }
                    at = @intCast(nodes.items[at][b]);
                }
            }
        }
        return .{ .node = try nodes.toOwnedSlice() };
    }
    fn decode(t: *const Tree, r: *Bits) u16 {
        var at: i16 = 0;
        var guard: u8 = 0;
        while (guard < 24) : (guard += 1) {
            const nx = t.node[@intCast(at)][r.bit()];
            if (nx < 0) return @intCast(-1 - nx);
            if (nx == 0) return 0;
            at = nx;
        }
        return 0;
    }
};

var tree_buf: [160 * 1024]u8 = undefined;
var trees: ?[13]Tree = null;

fn getTrees() *const [13]Tree {
    if (trees == null) {
        var fba = std.heap.FixedBufferAllocator.init(&tree_buf);
        var t: [13]Tree = undefined;
        t[0] = Tree.build(fba.allocator(), tab.scalefactor) catch unreachable;
        for (1..12) |k| t[k] = Tree.build(fba.allocator(), tab.spectral[k]) catch unreachable;
        t[12] = t[0];
        trees = t;
    }
    return &trees.?;
}

// ───────────── окна ─────────────

const Windows = struct {
    sine_long: [1024]f32,
    sine_short: [128]f32,
    kbd_long: [1024]f32,
    kbd_short: [128]f32,
};
var wins: ?Windows = null;

fn bessel0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 60) : (k += 1) {
        term *= (x / 2) * (x / 2) / (k * k);
        sum += term;
        if (term < sum * 1e-15) break;
    }
    return sum;
}

fn kbd(out: []f32, alpha: f64) void {
    const half = out.len; // N/2
    const n2: f64 = @floatFromInt(half);
    var w: [1025]f64 = undefined;
    var total: f64 = 0;
    for (0..half + 1) |i| {
        const t = (@as(f64, @floatFromInt(i)) - n2 / 2) / (n2 / 2);
        w[i] = bessel0(std.math.pi * alpha * @sqrt(@max(0, 1 - t * t)));
        total += w[i];
    }
    var acc: f64 = 0;
    for (0..half) |i| {
        acc += w[i];
        out[i] = @floatCast(@sqrt(acc / total));
    }
}

fn getWins() *const Windows {
    if (wins == null) {
        var w: Windows = undefined;
        for (0..1024) |i| w.sine_long[i] = @floatCast(@sin(std.math.pi / 2048.0 * (@as(f64, @floatFromInt(i)) + 0.5)));
        for (0..128) |i| w.sine_short[i] = @floatCast(@sin(std.math.pi / 256.0 * (@as(f64, @floatFromInt(i)) + 0.5)));
        kbd(&w.kbd_long, 4);
        kbd(&w.kbd_short, 6);
        wins = w;
    }
    return &wins.?;
}

// ───────────── декодер ─────────────

const Ics = struct {
    seq: u2 = 0,
    shape: u1 = 0,
    max_sfb: u8 = 0,
    groups: u8 = 1,
    glen: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    cb: [8][64]u8 = undefined,
    sf: [8][64]i32 = undefined,
    coef: [1024]f32 = undefined,
    tns: bool = false,
    tns_n: [8]u8 = undefined,
    tns_len: [8][4]u8 = undefined,
    tns_order: [8][4]u8 = undefined,
    tns_dir: [8][4]bool = undefined,
    tns_lpc: [8][4][21]f32 = undefined,
};

const Chan = struct {
    overlap: [1024]f32 = .{0} ** 1024,
    prev_shape: u1 = 0,
};

pub const Decoder = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    track: Track,
    rate: u32,
    sri: u4,
    channels: u8,
    frame: usize = 0,
    imdct_long: Imdct,
    imdct_short: Imdct,
    chan: [max_ch]Chan = .{Chan{}} ** max_ch,
    ics: [2]Ics = .{ Ics{}, Ics{} },
    /// Отсчёты последнего кадра по каналам (до 1024).
    out: [max_ch][1024]f32 = undefined,
    nout: u8 = 0,
    skip: u64,
    left: u64,
    rng: u32 = 0x1f2e3d4c,

    pub fn init(gpa: std.mem.Allocator, data: []const u8) Error!*Decoder {
        const d = try gpa.create(Decoder);
        errdefer gpa.destroy(d);
        d.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = data, .track = undefined, .rate = 0, .sri = 0, .channels = 0, .imdct_long = undefined, .imdct_short = undefined, .skip = 0, .left = 0 };
        errdefer d.arena.deinit();
        const a = d.arena.allocator();
        d.track = try readTrack(a, data);
        // AudioSpecificConfig
        var r = Bits{ .b = d.track.asc };
        var aot = r.get(5);
        if (aot == 31) aot = 32 + r.get(6);
        const sri = r.get(4);
        if (sri == 15) return error.Unsupported; // явная частота
        var cfg = r.get(4);
        if (aot == 5 or aot == 29) {
            // SBR/PS: дальше — частота расширения и ядро
            const ext = r.get(4);
            if (ext == 15) _ = r.get(24);
            aot = r.get(5);
            if (aot == 22) cfg = r.get(4);
        }
        if (aot != 2) return error.Unsupported; // только LC
        if (r.get(1) != 0) return error.Unsupported; // кадр 960
        if (sri > 12) return error.Damaged;
        d.sri = @intCast(sri);
        d.rate = tab.rates[sri];
        d.channels = if (cfg >= 1 and cfg <= 7) ([_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 })[cfg] else @intCast(@min(d.track.channels, max_ch));
        if (d.channels == 0) return error.Unsupported;
        d.imdct_long = try Imdct.init(a, 1024);
        d.imdct_short = try Imdct.init(a, 128);
        _ = getTrees();
        _ = getWins();
        d.skip = d.track.skip;
        d.left = if (d.track.duration > 0) d.track.duration else std.math.maxInt(u64);
        return d;
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        d.arena.deinit();
        gpa.destroy(d);
    }

    /// Следующий кадр: отсчёты в out[c][0..n]; 0 — конец.
    pub fn next(d: *Decoder) usize {
        while (d.frame < d.track.sizes.len) {
            const i = d.frame;
            d.frame += 1;
            const off = d.track.offsets[i];
            const sz = d.track.sizes[i];
            if (off + sz > d.data.len) return 0;
            d.block(d.data[@intCast(off)..@intCast(off + sz)]) catch {
                for (0..d.channels) |c| @memset(&d.out[c], 0);
            };
            var n: usize = 1024;
            var start: usize = 0;
            if (d.skip > 0) {
                start = @intCast(@min(d.skip, 1024));
                d.skip -= start;
            }
            n -= start;
            if (n > d.left) n = @intCast(d.left);
            d.left -= n;
            if (n == 0) {
                if (d.left == 0) return 0;
                continue;
            }
            if (start > 0) for (0..d.channels) |c| std.mem.copyForwards(f32, d.out[c][0..n], d.out[c][start .. start + n]);
            return n;
        }
        return 0;
    }

    fn block(d: *Decoder, b: []const u8) Error!void {
        var r = Bits{ .b = b };
        var ch: usize = 0;
        while (!r.over()) {
            const id = r.get(3);
            switch (id) {
                0, 3 => { // SCE, LFE
                    _ = r.get(4);
                    try d.ics_(&r, &d.ics[0], false);
                    if (ch < d.channels) try d.finish(&d.ics[0], ch);
                    ch += 1;
                },
                1 => { // CPE
                    _ = r.get(4);
                    const common = r.get(1) == 1;
                    var ms: [8][64]bool = undefined;
                    var ms_present: u32 = 0;
                    if (common) {
                        try d.icsInfo(&r, &d.ics[0]);
                        d.ics[1].seq = d.ics[0].seq;
                        d.ics[1].shape = d.ics[0].shape;
                        d.ics[1].max_sfb = d.ics[0].max_sfb;
                        d.ics[1].groups = d.ics[0].groups;
                        d.ics[1].glen = d.ics[0].glen;
                        ms_present = r.get(2);
                        for (0..d.ics[0].groups) |g| for (0..d.ics[0].max_sfb) |s| {
                            ms[g][s] = switch (ms_present) {
                                1 => r.get(1) == 1,
                                2 => true,
                                else => false,
                            };
                        };
                    }
                    try d.ics_(&r, &d.ics[0], common);
                    try d.ics_(&r, &d.ics[1], common);
                    if (common) d.stereo(&ms, ms_present);
                    if (ch < d.channels) try d.finish(&d.ics[0], ch);
                    if (ch + 1 < d.channels) try d.finish(&d.ics[1], ch + 1);
                    ch += 2;
                },
                4 => { // DSE
                    _ = r.get(4);
                    const al = r.get(1) == 1;
                    var cnt = r.get(8);
                    if (cnt == 255) cnt += r.get(8);
                    if (al) r.pos = (r.pos + 7) & ~@as(usize, 7);
                    r.pos += cnt * 8;
                },
                5 => try pce(&r),
                6 => { // FIL
                    var cnt = r.get(4);
                    if (cnt == 15) cnt += r.get(8) -% 1;
                    r.pos += cnt * 8;
                },
                7 => break,
                else => return error.Unsupported, // CCE
            }
        }
        while (ch < d.channels) : (ch += 1) @memset(&d.out[ch], 0);
    }

    fn pce(r: *Bits) Error!void {
        _ = r.get(4 + 2 + 4);
        const nf = r.get(4);
        const ns = r.get(4);
        const nb = r.get(4);
        const nl = r.get(2);
        const na = r.get(3);
        const nc = r.get(4);
        if (r.get(1) == 1) _ = r.get(4);
        if (r.get(1) == 1) _ = r.get(4);
        if (r.get(1) == 1) _ = r.get(3);
        r.pos += (nf + ns + nb) * 5 + nl * 4 + na * 4 + nc * 5;
        r.pos = (r.pos + 7) & ~@as(usize, 7);
        const cl = r.get(8);
        r.pos += cl * 8;
    }

    fn icsInfo(d: *Decoder, r: *Bits, s: *Ics) Error!void {
        _ = d;
        _ = r.get(1);
        s.seq = @intCast(r.get(2));
        s.shape = @intCast(r.get(1));
        if (s.seq == 2) {
            s.max_sfb = @intCast(r.get(4));
            const grp = r.get(7);
            s.groups = 1;
            s.glen = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
            var k: u3 = 6;
            for (0..7) |_| {
                if ((grp >> k) & 1 == 1) {
                    s.glen[s.groups - 1] += 1;
                } else {
                    s.groups += 1;
                    s.glen[s.groups - 1] = 1;
                }
                if (k > 0) k -= 1;
            }
        } else {
            s.max_sfb = @intCast(r.get(6));
            s.groups = 1;
            s.glen = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
            if (r.get(1) == 1) return error.Unsupported; // предсказание (Main/LTP)
        }
    }

    fn swb(d: *const Decoder, s: *const Ics) []const u16 {
        return if (s.seq == 2) tab.swb_short[d.sri] else tab.swb_long[d.sri];
    }

    fn ics_(d: *Decoder, r: *Bits, s: *Ics, common: bool) Error!void {
        const gg: i32 = @intCast(r.get(8));
        if (!common) try d.icsInfo(r, s);
        const sw = d.swb(s);
        const nswb = sw.len - 1;
        if (s.max_sfb > nswb) return error.Damaged;
        const t = getTrees();
        const short = s.seq == 2;
        // секции
        for (0..s.groups) |g| {
            var k: usize = 0;
            while (k < s.max_sfb) {
                const cb: u8 = @intCast(r.get(4));
                if (cb == 12) return error.Damaged;
                const bits: u6 = if (short) 3 else 5;
                const esc: u32 = if (short) 7 else 31;
                var len: usize = 0;
                while (true) {
                    const inc = r.get(bits);
                    len += inc;
                    if (inc != esc) break;
                    if (r.over()) return error.Damaged;
                }
                if (k + len > s.max_sfb) return error.Damaged;
                for (k..k + len) |q| s.cb[g][q] = cb;
                k += len;
            }
        }
        // множители
        var sf = gg;
        var is_pos: i32 = 0;
        var noise = gg - 90;
        var first_noise = true;
        for (0..s.groups) |g| for (0..s.max_sfb) |k| {
            const cb = s.cb[g][k];
            switch (cb) {
                0 => s.sf[g][k] = 0,
                14, 15 => {
                    is_pos += @as(i32, t[0].decode(r)) - 60;
                    s.sf[g][k] = is_pos;
                },
                13 => {
                    if (first_noise) {
                        first_noise = false;
                        noise += @as(i32, @intCast(r.get(9))) - 256;
                    } else noise += @as(i32, t[0].decode(r)) - 60;
                    s.sf[g][k] = noise;
                },
                else => {
                    sf += @as(i32, t[0].decode(r)) - 60;
                    if (sf < 0 or sf > 255) return error.Damaged;
                    s.sf[g][k] = sf;
                },
            }
        };
        // импульсы
        var pulse_n: usize = 0;
        var pulse_start: usize = 0;
        var pulse_off: [4]u8 = undefined;
        var pulse_amp: [4]u8 = undefined;
        if (r.get(1) == 1) {
            if (short) return error.Damaged;
            pulse_n = r.get(2) + 1;
            pulse_start = r.get(6);
            for (0..pulse_n) |i| {
                pulse_off[i] = @intCast(r.get(5));
                pulse_amp[i] = @intCast(r.get(4));
            }
        }
        // TNS
        s.tns = r.get(1) == 1;
        if (s.tns) {
            const nw: usize = if (short) 8 else 1;
            for (0..nw) |w| {
                s.tns_n[w] = @intCast(r.get(if (short) 1 else 2));
                if (s.tns_n[w] == 0) continue;
                const res: u6 = @intCast(r.get(1) + 3);
                for (0..s.tns_n[w]) |f| {
                    s.tns_len[w][f] = @intCast(r.get(if (short) 4 else 6));
                    const order: u8 = @intCast(r.get(if (short) 3 else 5));
                    s.tns_order[w][f] = order;
                    if (order == 0) continue;
                    s.tns_dir[w][f] = r.get(1) == 1;
                    const compress: u6 = @intCast(r.get(1));
                    const cbits: u6 = res - compress;
                    var tmp: [20]f32 = undefined;
                    const iq: f32 = (@as(f32, @floatFromInt(@as(u32, 1) << @intCast(res - 1))) - 0.5) / (std.math.pi / 2.0);
                    const iqm: f32 = (@as(f32, @floatFromInt(@as(u32, 1) << @intCast(res - 1))) + 0.5) / (std.math.pi / 2.0);
                    for (0..order) |i| {
                        var c: i32 = @intCast(r.get(cbits));
                        if (c >= @as(i32, 1) << @intCast(cbits - 1)) c -= @as(i32, 1) << @intCast(cbits);
                        const cf: f32 = @floatFromInt(c);
                        tmp[i] = @sin(cf / (if (c >= 0) iq else iqm));
                    }
                    // в коэффициенты LPC
                    var lpc = &s.tns_lpc[w][f];
                    lpc[0] = 1;
                    var bb: [21]f32 = undefined;
                    for (1..order + 1) |m| {
                        for (1..m) |i| bb[i] = lpc[i] + tmp[m - 1] * lpc[m - i];
                        for (1..m) |i| lpc[i] = bb[i];
                        lpc[m] = tmp[m - 1];
                    }
                }
            }
        }
        if (r.get(1) == 1) return error.Unsupported; // gain control (SSR)
        // спектр
        var q: [1024]i32 = .{0} ** 1024;
        var wstart: usize = 0;
        for (0..s.groups) |g| {
            const gl = s.glen[g];
            for (0..s.max_sfb) |k| {
                const cb = s.cb[g][k];
                if (cb == 0 or cb >= 13) continue;
                const dims: usize = if (cb < 5) 4 else 2;
                const unsigned = cb == 3 or cb == 4 or cb >= 7;
                const mods = [12]u32{ 0, 3, 3, 3, 3, 9, 9, 8, 8, 13, 13, 17 };
                const md = mods[cb];
                for (0..gl) |wi| {
                    const base = (wstart + wi) * (if (short) @as(usize, 128) else 1024);
                    var i: usize = sw[k];
                    while (i < sw[k + 1]) : (i += dims) {
                        var idx: u32 = t[cb].decode(r);
                        var v: [4]i32 = undefined;
                        var j: usize = dims;
                        while (j > 0) {
                            j -= 1;
                            v[j] = @intCast(idx % md);
                            idx /= md;
                        }
                        if (!unsigned) {
                            const off: i32 = @intCast(md / 2);
                            for (0..dims) |x| v[x] -= off;
                        } else {
                            for (0..dims) |x| if (v[x] != 0 and r.get(1) == 1) {
                                v[x] = -v[x];
                            };
                            if (cb == 11) for (0..dims) |x| if (@abs(v[x]) == 16) {
                                var n: u6 = 4;
                                while (r.get(1) == 1 and n < 13) n += 1;
                                const e: i32 = @intCast((@as(u32, 1) << @intCast(n)) + r.get(n));
                                v[x] = if (v[x] < 0) -e else e;
                            };
                        }
                        for (0..dims) |x| q[base + i + x] = v[x];
                    }
                }
            }
            wstart += gl;
        }
        if (r.over()) return error.Damaged;
        // импульсы
        if (pulse_n > 0) {
            if (pulse_start >= nswb) return error.Damaged;
            var k: usize = sw[pulse_start];
            for (0..pulse_n) |i| {
                k += pulse_off[i];
                if (k >= 1024) return error.Damaged;
                if (q[k] > 0) q[k] += pulse_amp[i] else q[k] -= pulse_amp[i];
            }
        }
        // деквантование и шум
        @memset(&s.coef, 0);
        wstart = 0;
        for (0..s.groups) |g| {
            const gl = s.glen[g];
            for (0..s.max_sfb) |k| {
                const cb = s.cb[g][k];
                for (0..gl) |wi| {
                    const base = (wstart + wi) * (if (short) @as(usize, 128) else 1024);
                    const lo = base + sw[k];
                    const hi = base + sw[k + 1];
                    if (cb == 13) {
                        var e: f32 = 0;
                        for (lo..hi) |i| {
                            d.rng = d.rng *% 1664525 +% 1013904223;
                            const x: f32 = @floatFromInt(@as(i32, @bitCast(d.rng)));
                            s.coef[i] = x;
                            e += x * x;
                        }
                        const scale = std.math.exp2(0.25 * @as(f32, @floatFromInt(s.sf[g][k]))) / @sqrt(@max(e, 1e-30));
                        for (lo..hi) |i| s.coef[i] *= scale;
                    } else if (cb != 0 and cb < 13) {
                        const scale = std.math.exp2(0.25 * @as(f32, @floatFromInt(s.sf[g][k] - 100)));
                        for (lo..hi) |i| {
                            const v = q[i];
                            if (v != 0) {
                                const m = std.math.pow(f32, @floatFromInt(@abs(v)), 4.0 / 3.0) * scale;
                                s.coef[i] = if (v < 0) -m else m;
                            }
                        }
                    }
                }
            }
            wstart += gl;
        }
    }

    fn stereo(d: *Decoder, ms: *const [8][64]bool, ms_present: u32) void {
        const l = &d.ics[0];
        const rr = &d.ics[1];
        const sw = d.swb(l);
        const short = l.seq == 2;
        var wstart: usize = 0;
        for (0..l.groups) |g| {
            const gl = l.glen[g];
            for (0..l.max_sfb) |k| {
                const rcb = rr.cb[g][k];
                for (0..gl) |wi| {
                    const base = (wstart + wi) * (if (short) @as(usize, 128) else 1024);
                    const lo = base + sw[k];
                    const hi = base + sw[k + 1];
                    if (rcb == 14 or rcb == 15) {
                        var sc = std.math.exp2(-0.25 * @as(f32, @floatFromInt(rr.sf[g][k])));
                        if (rcb == 14) sc = -sc;
                        if (ms_present == 1 and ms[g][k]) sc = -sc;
                        for (lo..hi) |i| rr.coef[i] = l.coef[i] * sc;
                    } else if (ms_present != 0 and ms[g][k] and l.cb[g][k] != 13 and rcb != 13) {
                        for (lo..hi) |i| {
                            const a = l.coef[i];
                            const b = rr.coef[i];
                            l.coef[i] = a + b;
                            rr.coef[i] = a - b;
                        }
                    }
                }
            }
            wstart += gl;
        }
    }

    /// TNS, банк фильтров и сложение с перекрытием → out[ch].
    fn finish(d: *Decoder, s: *Ics, ch: usize) Error!void {
        const short = s.seq == 2;
        const sw = d.swb(s);
        if (s.tns) {
            const nw: usize = if (short) 8 else 1;
            const tmax: usize = if (short) tab.tns_max_short[d.sri] else tab.tns_max_long[d.sri];
            const mmm = @min(tmax, s.max_sfb);
            const nswb = sw.len - 1;
            for (0..nw) |w| {
                var top: usize = nswb;
                for (0..s.tns_n[w]) |f| {
                    const bottom = top -| s.tns_len[w][f];
                    defer top = bottom;
                    const order = s.tns_order[w][f];
                    if (order == 0) continue;
                    const start = sw[@min(bottom, mmm)];
                    const end = sw[@min(top, mmm)];
                    if (end <= start) continue;
                    const size = end - start;
                    const base = w * (if (short) @as(usize, 128) else 1024);
                    const lpc = &s.tns_lpc[w][f];
                    const c = s.coef[base..];
                    if (!s.tns_dir[w][f]) {
                        for (0..size) |m| {
                            const at = start + m;
                            for (1..@min(m, order) + 1) |i| c[at] -= lpc[i] * c[at - i];
                        }
                    } else {
                        for (0..size) |m| {
                            const at = end - 1 - m;
                            for (1..@min(m, order) + 1) |i| c[at] -= lpc[i] * c[at + i];
                        }
                    }
                }
            }
        }
        const cs = &d.chan[ch];
        const wv = getWins();
        const prev_long = if (cs.prev_shape == 1) &wv.kbd_long else &wv.sine_long;
        const prev_short = if (cs.prev_shape == 1) &wv.kbd_short else &wv.sine_short;
        const cur_long = if (s.shape == 1) &wv.kbd_long else &wv.sine_long;
        const cur_short = if (s.shape == 1) &wv.kbd_short else &wv.sine_short;
        var z: [2048]f32 = undefined;
        const k_long: f32 = 1.0 / (1024.0 * 32768.0);
        const k_short: f32 = 1.0 / (128.0 * 32768.0);
        if (!short) {
            var x: [2048]f32 = undefined;
            d.imdct_long.run(&s.coef, &x);
            for (0..2048) |i| x[i] *= k_long;
            switch (s.seq) {
                0 => for (0..1024) |i| {
                    z[i] = x[i] * prev_long[i];
                    z[1024 + i] = x[1024 + i] * cur_long[1023 - i];
                },
                1 => for (0..2048) |i| {
                    z[i] = if (i < 1024) x[i] * prev_long[i] else if (i < 1472) x[i] else if (i < 1600) x[i] * cur_short[127 - (i - 1472)] else 0;
                },
                else => for (0..2048) |i| {
                    z[i] = if (i < 448) 0 else if (i < 576) x[i] * prev_short[i - 448] else if (i < 1024) x[i] else x[i] * cur_long[1023 - (i - 1024)];
                },
            }
        } else {
            @memset(&z, 0);
            for (0..8) |w| {
                var x: [256]f32 = undefined;
                d.imdct_short.run(s.coef[w * 128 ..][0..128], &x);
                const rise = if (w == 0) prev_short else cur_short;
                for (0..256) |i| {
                    const win = if (i < 128) rise[i] else cur_short[255 - i];
                    z[448 + 128 * w + i] += x[i] * k_short * win;
                }
            }
        }
        for (0..1024) |i| {
            d.out[ch][i] = z[i] + cs.overlap[i];
            cs.overlap[i] = z[1024 + i];
        }
        cs.prev_shape = s.shape;
    }
};

test "aac: коды Хаффмана полны и префиксны" {
    for (1..12) |k| {
        const h = tab.spectral[k];
        var kraft: f64 = 0;
        for (h.lens) |l| kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(l)));
        try std.testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-12);
    }
}
