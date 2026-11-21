//! Разбор MP3 (MPEG-1, MPEG-2, MPEG-2.5 Layer III) в отсчёты f32 (BACKLOG_RU.md §22).
//!
//! Заголовки кадров, побочная информация, запас битов (bit reservoir),
//! множители масштаба MPEG-1 и MPEG-2, коды Хаффмана, деквантование,
//! стерео M/S и интенсивное, перестановка коротких блоков, снятие наложения,
//! обратное МДКП (длинные, короткие, смешанные блоки) и многофазный синтез.
//! Теги ID3v2 в начале, ID3v1 и APE в конце, служебный кадр Xing/Info/VBRI
//! пропускаются. Свободный битрейт и Layer I/II не берутся.

const std = @import("std");
const tab = @import("mp3tab.zig");

pub const Error = error{ NotMp3, Unsupported, OutOfMemory };

// ───────────── заголовок кадра ─────────────

pub const Header = struct {
    /// 0 — MPEG-1, 1 — MPEG-2, 2 — MPEG-2.5
    ver: u2,
    rate: u32,
    rate_idx: u4, // 0..8 по всем версиям
    bitrate: u32, // кбит/с
    pad: bool,
    crc: bool,
    mode: u2, // 0 стерео, 1 joint, 2 два канала, 3 моно
    ext: u2,
    size: usize,

    pub fn channels(h: Header) u8 {
        return if (h.mode == 3) 1 else 2;
    }
    pub fn granules(h: Header) u8 {
        return if (h.ver == 0) 2 else 1;
    }
    pub fn sideSize(h: Header) usize {
        if (h.ver == 0) return if (h.mode == 3) 17 else 32;
        return if (h.mode == 3) 9 else 17;
    }
};

const br1 = [15]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
const br2 = [15]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };
const rates = [9]u32{ 44100, 48000, 32000, 22050, 24000, 16000, 11025, 12000, 8000 };

pub fn header(b: []const u8) ?Header {
    if (b.len < 4) return null;
    if (b[0] != 0xFF or b[1] & 0xE0 != 0xE0) return null;
    const vbits = (b[1] >> 3) & 3;
    if (vbits == 1) return null;
    if ((b[1] >> 1) & 3 != 1) return null; // только Layer III
    const bri = b[2] >> 4;
    const sri = (b[2] >> 2) & 3;
    if (bri == 0 or bri == 15 or sri == 3) return null;
    const ver: u2 = switch (vbits) {
        3 => 0,
        2 => 1,
        else => 2,
    };
    const ridx: u4 = @intCast(@as(u8, ver) * 3 + sri);
    const rate = rates[ridx];
    const kbps: u32 = if (ver == 0) br1[bri] else br2[bri];
    const pad = (b[2] >> 1) & 1 == 1;
    const per: u32 = if (ver == 0) 144 else 72;
    const size = per * kbps * 1000 / rate + @intFromBool(pad);
    return .{
        .ver = ver,
        .rate = rate,
        .rate_idx = ridx,
        .bitrate = kbps,
        .pad = pad,
        .crc = b[1] & 1 == 0,
        .mode = @intCast(b[3] >> 6),
        .ext = @intCast((b[3] >> 4) & 3),
        .size = size,
    };
}

/// Размер тега ID3v2 в начале (0 — тега нет).
pub fn id3v2Size(b: []const u8) usize {
    if (b.len < 10 or !std.mem.eql(u8, b[0..3], "ID3")) return 0;
    const n = (@as(usize, b[6] & 0x7F) << 21) | (@as(usize, b[7] & 0x7F) << 14) | (@as(usize, b[8] & 0x7F) << 7) | (b[9] & 0x7F);
    const footer: usize = if (b[5] & 0x10 != 0) 10 else 0;
    return 10 + n + footer;
}

/// Конец звука: без ID3v1 (128 байт «TAG») и APEv2 перед ним.
fn audioEnd(b: []const u8) usize {
    var end = b.len;
    if (end >= 128 and std.mem.eql(u8, b[end - 128 .. end - 125], "TAG")) end -= 128;
    if (end >= 32 and std.mem.eql(u8, b[end - 32 .. end - 24], "APETAGEX")) {
        const sz = std.mem.readInt(u32, b[end - 20 ..][0..4], .little);
        const flags = std.mem.readInt(u32, b[end - 12 ..][0..4], .little);
        const total = sz + (if (flags & 0x80000000 != 0) @as(usize, 32) else 0);
        if (total <= end) end -= total;
    }
    return end;
}

/// Похоже ли начало файла на MP3: два кадра подряд с одинаковыми параметрами.
pub fn looksLike(b: []const u8) bool {
    var d = Decoder.init(b) catch return false;
    _ = &d;
    return true;
}

// ───────────── чтение битов ─────────────

const Bits = struct {
    buf: []const u8,
    pos: usize = 0, // в битах

    fn get(r: *Bits, n: u5) u32 {
        if (n == 0) return 0;
        var v: u32 = 0;
        var k: u5 = 0;
        while (k < n) : (k += 1) v = (v << 1) | r.bit();
        return v;
    }
    fn bit(r: *Bits) u32 {
        const byte = r.pos >> 3;
        const v: u32 = if (byte < r.buf.len) (r.buf[byte] >> @intCast(7 - (r.pos & 7))) & 1 else 0;
        r.pos += 1;
        return v;
    }
};

// ───────────── дерево Хаффмана ─────────────

/// Узел: >= 0 — переход к узлу, < 0 — лист (-1 - значение).
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
                const b: usize = (@as(u32, code) >> k) & 1;
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

    fn decode(t: Tree, r: *Bits) u16 {
        var at: i16 = 0;
        var guard: u8 = 0;
        while (guard < 24) : (guard += 1) {
            const nx = t.node[@intCast(at)][r.bit()];
            if (nx < 0) return @intCast(-1 - nx);
            if (nx == 0) return 0; // испорченный поток
            at = nx;
        }
        return 0;
    }
};

const Trees = struct {
    big: [32]?Tree,
    quad: [2]Tree,
};

var trees_buf: [64 * 1024]u8 = undefined;
var trees: ?Trees = null;

fn getTrees() *const Trees {
    if (trees == null) {
        var fba = std.heap.FixedBufferAllocator.init(&trees_buf);
        const a = fba.allocator();
        var t: Trees = undefined;
        var built: [32]?Tree = .{null} ** 32;
        for (tab.big, 0..) |h, i| {
            const hh = h orelse continue;
            // таблицы 16..23 и 24..31 общие
            if (i > 16 and i < 24) built[i] = built[16] else if (i > 24) built[i] = built[24] else built[i] = Tree.build(a, hh) catch unreachable;
        }
        t.big = built;
        t.quad[0] = Tree.build(a, tab.quad[0]) catch unreachable;
        t.quad[1] = Tree.build(a, tab.quad[1]) catch unreachable;
        trees = t;
    }
    return &trees.?;
}

// ───────────── полосы масштаба ─────────────

const long_w = [9][22]u8{
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192 },
    .{ 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54 },
    .{ 12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2 },
};
const short_w = [9][13]u8{
    .{ 4, 4, 4, 4, 6, 8, 10, 12, 14, 18, 22, 30, 56 },
    .{ 4, 4, 4, 4, 6, 6, 10, 12, 14, 16, 20, 26, 66 },
    .{ 4, 4, 4, 4, 6, 8, 12, 16, 20, 26, 34, 42, 12 },
    .{ 4, 4, 4, 6, 6, 8, 10, 14, 18, 26, 32, 42, 18 },
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 32, 44, 12 },
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 },
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 },
    .{ 4, 4, 4, 6, 8, 10, 12, 14, 18, 24, 30, 40, 18 },
    .{ 8, 8, 8, 12, 16, 20, 24, 28, 36, 2, 2, 2, 26 },
};

pub fn longWidths(ridx: u4) *const [22]u8 {
    return &long_w[ridx];
}

const pretab = [22]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };
const slen_t = [2][16]u8{
    .{ 0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4 },
    .{ 0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3 },
};
const nr_sfb = [6][3][4]u8{
    .{ .{ 6, 5, 5, 5 }, .{ 9, 9, 9, 9 }, .{ 6, 9, 9, 9 } },
    .{ .{ 6, 5, 7, 3 }, .{ 9, 9, 12, 6 }, .{ 6, 9, 12, 6 } },
    .{ .{ 11, 10, 0, 0 }, .{ 18, 18, 0, 0 }, .{ 15, 18, 0, 0 } },
    .{ .{ 7, 7, 7, 0 }, .{ 12, 12, 12, 0 }, .{ 6, 15, 12, 0 } },
    .{ .{ 6, 6, 6, 3 }, .{ 12, 9, 9, 6 }, .{ 6, 12, 9, 6 } },
    .{ .{ 8, 8, 5, 0 }, .{ 15, 12, 9, 0 }, .{ 6, 18, 9, 0 } },
};

/// Раскладка гранулы: ширины «записей» полос по порядку спектра. Для коротких
/// полос каждая повторена трижды (окна 0, 1, 2).
const Layout = struct {
    w: [40]u8 = undefined,
    n: u8 = 0,
    /// Сколько первых записей — длинные полосы.
    n_long: u8 = 0,
    /// Номер полосы каждой записи (для длинных — 0..21, для коротких — 0..12).
    band: [40]u8 = undefined,

    fn make(g: *const Granule, ridx: u4, mpeg1: bool) Layout {
        var l = Layout{};
        if (g.block_type != 2) {
            for (long_w[ridx], 0..) |w, i| l.push(w, @intCast(i));
            l.n_long = 22;
            return l;
        }
        var first_short: u8 = 0;
        if (g.mixed) {
            const nl: u8 = if (mpeg1) 8 else 6;
            var i: u8 = 0;
            while (i < nl) : (i += 1) l.push(long_w[ridx][i], i);
            l.n_long = nl;
            first_short = 3;
        }
        var b = first_short;
        while (b < 13) : (b += 1) {
            for (0..3) |_| l.push(short_w[ridx][b], b);
        }
        return l;
    }
    fn push(l: *Layout, w: u8, band: u8) void {
        l.w[l.n] = w;
        l.band[l.n] = band;
        l.n += 1;
    }
};

// ───────────── побочная информация ─────────────

const Granule = struct {
    part23: u32 = 0,
    big_values: u32 = 0,
    global_gain: u32 = 0,
    sfc: u32 = 0,
    block_type: u2 = 0,
    mixed: bool = false,
    table: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u8 = .{ 0, 0, 0 },
    region0: u32 = 0,
    region1: u32 = 0,
    preflag: bool = false,
    sf_scale: bool = false,
    count1_table: u1 = 0,
};

const Side = struct {
    main_begin: u32,
    scfsi: [2][4]bool,
    gr: [2][2]Granule,
};

fn readSide(r: *Bits, h: Header) Side {
    var s: Side = .{ .main_begin = 0, .scfsi = .{ .{ false, false, false, false }, .{ false, false, false, false } }, .gr = undefined };
    const nch = h.channels();
    if (h.ver == 0) {
        s.main_begin = r.get(9);
        _ = r.get(if (nch == 1) 5 else 3);
        for (0..nch) |ch| for (0..4) |k| {
            s.scfsi[ch][k] = r.get(1) == 1;
        };
    } else {
        s.main_begin = r.get(8);
        _ = r.get(if (nch == 1) 1 else 2);
    }
    for (0..h.granules()) |gi| for (0..nch) |ch| {
        var g = Granule{};
        g.part23 = r.get(12);
        g.big_values = @min(r.get(9), 288);
        g.global_gain = r.get(8);
        g.sfc = r.get(if (h.ver == 0) 4 else 9);
        if (r.get(1) == 1) {
            g.block_type = @intCast(r.get(2));
            g.mixed = r.get(1) == 1;
            g.table[0] = @intCast(r.get(5));
            g.table[1] = @intCast(r.get(5));
            for (0..3) |w| g.subblock_gain[w] = @intCast(r.get(3));
            if (g.block_type == 0) g.block_type = 1; // недопустимо; как «начало»
            g.region0 = if (g.block_type == 2 and !g.mixed) 8 else 7;
            g.region1 = 36; // всё остальное
        } else {
            for (0..3) |k| g.table[k] = @intCast(r.get(5));
            g.region0 = r.get(4);
            g.region1 = r.get(3);
        }
        if (h.ver == 0) g.preflag = r.get(1) == 1;
        g.sf_scale = r.get(1) == 1;
        g.count1_table = @intCast(r.get(1));
        s.gr[gi][ch] = g;
    };
    return s;
}

// ───────────── декодер ─────────────

const Synth = struct {
    v: [1024]f32 = .{0} ** 1024,
    off: usize = 0,
};

pub const Decoder = struct {
    data: []const u8,
    pos: usize,
    end: usize,
    rate: u32,
    channels: u8,
    first: Header,
    res: [4096]u8 = undefined,
    res_len: usize = 0,
    overlap: [2][32][18]f32 = std.mem.zeroes([2][32][18]f32),
    synth: [2]Synth = .{ .{}, .{} },
    /// Отсчёты последнего кадра по каналам (моно — только [0]).
    pcm: [2][1152]f32 = undefined,
    scf: [2][40]u8 = std.mem.zeroes([2][40]u8),
    frames: u64 = 0,
    /// Предел значения интенсивного стерео по группам (MPEG-2): максимум — «не интенсивное».
    is_max: [4]u32 = .{ 0, 0, 0, 0 },
    is_slen: [4]u5 = .{ 0, 0, 0, 0 },
    is_nr: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn init(data: []const u8) Error!Decoder {
        const start = id3v2Size(data);
        const end = audioEnd(data);
        if (start >= end) return error.NotMp3;
        // первый кадр, за которым сразу идёт ещё один с теми же параметрами
        var p = start;
        const limit = @min(end, start + 256 * 1024);
        while (p + 4 <= limit) : (p += 1) {
            const h = header(data[p..end]) orelse continue;
            const q = p + h.size;
            if (q + 4 <= end) {
                const h2 = header(data[q..end]) orelse continue;
                if (h2.ver != h.ver or h2.rate != h.rate or h2.channels() != h.channels()) continue;
            } else if (q > end) continue;
            var d = Decoder{ .data = data, .pos = p, .end = end, .rate = h.rate, .channels = h.channels(), .first = h };
            if (isInfoFrame(data[p..end], h)) d.pos = q;
            _ = getTrees();
            return d;
        }
        return error.NotMp3;
    }

    fn isInfoFrame(b: []const u8, h: Header) bool {
        const off = 4 + h.sideSize() + @as(usize, if (h.crc) 2 else 0);
        if (b.len < off + 4) return false;
        const tag = b[off..][0..4];
        if (std.mem.eql(u8, tag, "Xing") or std.mem.eql(u8, tag, "Info")) return true;
        return b.len >= 36 + 4 and std.mem.eql(u8, b[36..40], "VBRI");
    }

    /// Следующий кадр: число отсчётов на канал в `pcm` (0 — конец).
    pub fn next(d: *Decoder) usize {
        while (d.pos + 4 <= d.end) {
            const h = header(d.data[d.pos..d.end]) orelse {
                d.pos += 1;
                continue;
            };
            if (h.rate != d.rate or h.channels() != d.channels or d.pos + h.size > d.end) {
                d.pos += 1;
                continue;
            }
            const fr = d.data[d.pos .. d.pos + h.size];
            d.pos += h.size;
            d.frames += 1;
            return d.frame(h, fr);
        }
        return 0;
    }

    fn frame(d: *Decoder, h: Header, f: []const u8) usize {
        const so: usize = 4 + @as(usize, if (h.crc) 2 else 0);
        const ss = h.sideSize();
        if (f.len < so + ss) return d.silence(h);
        var sr = Bits{ .buf = f[so .. so + ss] };
        var side = readSide(&sr, h);
        const main = f[so + ss ..];
        // запас битов: main_data_begin байт назад от начала данных этого кадра
        const have = d.res_len;
        if (d.res_len + main.len > d.res.len) {
            const drop = d.res_len + main.len - d.res.len;
            std.mem.copyForwards(u8, d.res[0 .. d.res_len - drop], d.res[drop..d.res_len]);
            d.res_len -= drop;
        }
        const have2 = d.res_len;
        @memcpy(d.res[d.res_len .. d.res_len + main.len], main);
        d.res_len += main.len;
        if (side.main_begin > have2 or (have == 0 and side.main_begin > 0)) return d.silence(h);
        var r = Bits{ .buf = d.res[0..d.res_len], .pos = (have2 - side.main_begin) * 8 };

        const nch = h.channels();
        const ngr = h.granules();
        var xr: [2][576]f32 = undefined;
        for (0..ngr) |gi| {
            var layouts: [2]Layout = undefined;
            var nonzero: [2]usize = .{ 0, 0 };
            for (0..nch) |ch| {
                const g = &side.gr[gi][ch];
                const start = r.pos;
                layouts[ch] = Layout.make(g, h.rate_idx, h.ver == 0);
                if (h.ver == 0) d.scalefactors1(&r, g, &side.scfsi[ch], gi, ch, &layouts[ch]) else d.scalefactors2(&r, g, h, ch, &layouts[ch]);
                var is: [576]i32 = undefined;
                nonzero[ch] = huffman(&r, g, &layouts[ch], start + g.part23, &is);
                dequant(g, &layouts[ch], &d.scf[ch], &is, &xr[ch], h.ver == 0);
                r.pos = start + g.part23;
            }
            if (nch == 2 and h.mode == 1) d.stereo(h, &side.gr[gi][1], &layouts[1], &xr, nonzero[1]);
            for (0..nch) |ch| {
                const g = &side.gr[gi][ch];
                reorder(g, &layouts[ch], &xr[ch]);
                antialias(g, &xr[ch]);
                var out: [18][32]f32 = undefined;
                d.hybrid(g, ch, &xr[ch], &out);
                for (0..18) |t| d.synthesize(ch, &out[t], d.pcm[ch][gi * 576 + t * 32 ..][0..32]);
            }
        }
        return 576 * @as(usize, ngr);
    }

    fn silence(d: *Decoder, h: Header) usize {
        const n = 576 * @as(usize, h.granules());
        for (0..h.channels()) |ch| @memset(d.pcm[ch][0..n], 0);
        return n;
    }

    fn scalefactors1(d: *Decoder, r: *Bits, g: *const Granule, scfsi: *const [4]bool, gi: usize, ch: usize, l: *const Layout) void {
        const s1: u5 = @intCast(slen_t[0][g.sfc]);
        const s2: u5 = @intCast(slen_t[1][g.sfc]);
        const sf = &d.scf[ch];
        if (g.block_type == 2) {
            var k: usize = 0;
            if (g.mixed) {
                while (k < 8) : (k += 1) sf[k] = @intCast(r.get(s1));
            }
            // короткие полосы до 5 включительно — slen1, 6..11 — slen2, 12 — ноль
            while (k < l.n) : (k += 1) {
                const band = l.band[k];
                sf[k] = if (band < 6) @intCast(r.get(s1)) else if (band < 12) @intCast(r.get(s2)) else 0;
            }
            return;
        }
        const groups = [5]u8{ 0, 6, 11, 16, 21 };
        for (0..4) |gr| {
            const lo = groups[gr];
            const hi = groups[gr + 1];
            const sl = if (gr < 2) s1 else s2;
            if (gi == 1 and scfsi[gr]) continue; // берутся из первой гранулы
            for (lo..hi) |k| sf[k] = @intCast(r.get(sl));
        }
        sf[21] = 0;
    }

    fn scalefactors2(d: *Decoder, r: *Bits, g: *Granule, h: Header, ch: usize, l: *const Layout) void {
        var slen: [4]u5 = .{ 0, 0, 0, 0 };
        var ti: usize = 0;
        var sfc = g.sfc;
        const is_right = ch == 1 and h.mode == 1 and h.ext & 1 != 0;
        if (is_right) sfc >>= 1;
        const gg = g;
        gg.preflag = false;
        if (!is_right) {
            if (sfc < 400) {
                slen = .{ @intCast((sfc >> 4) / 5), @intCast((sfc >> 4) % 5), @intCast((sfc & 15) >> 2), @intCast(sfc & 3) };
                ti = 0;
            } else if (sfc < 500) {
                sfc -= 400;
                slen = .{ @intCast((sfc >> 2) / 5), @intCast((sfc >> 2) % 5), @intCast(sfc & 3), 0 };
                ti = 1;
            } else {
                sfc -= 500;
                slen = .{ @intCast(sfc / 3), @intCast(sfc % 3), 0, 0 };
                ti = 2;
                gg.preflag = true;
            }
        } else {
            if (sfc < 180) {
                slen = .{ @intCast(sfc / 36), @intCast((sfc % 36) / 6), @intCast((sfc % 36) % 6), 0 };
                ti = 3;
            } else if (sfc < 244) {
                sfc -= 180;
                slen = .{ @intCast((sfc % 64) >> 4), @intCast((sfc % 16) >> 2), @intCast(sfc % 4), 0 };
                ti = 4;
            } else {
                sfc -= 244;
                slen = .{ @intCast(sfc / 3), @intCast(sfc % 3), 0, 0 };
                ti = 5;
            }
        }
        const bt: usize = if (g.block_type != 2) 0 else if (g.mixed) 2 else 1;
        const sf = &d.scf[ch];
        var k: usize = 0;
        for (0..4) |part| {
            const n = nr_sfb[ti][bt][part];
            for (0..n) |_| {
                if (k < sf.len) sf[k] = @intCast(r.get(slen[part]));
                k += 1;
            }
            d.is_max[part] = if (slen[part] == 0) 0 else (@as(u32, 1) << slen[part]) - 1;
        }
        _ = l;
        while (k < sf.len) : (k += 1) sf[k] = 0;
        d.is_slen = slen;
        d.is_nr = nr_sfb[ti][bt];
    }

    fn stereo(d: *Decoder, h: Header, gr: *const Granule, l: *const Layout, xr: *[2][576]f32, right_nz: usize) void {
        const ms = h.ext & 2 != 0;
        const intensity = h.ext & 1 != 0;
        var is_from: usize = 576;
        if (intensity) {
            is_from = d.intensityStereo(h, gr, l, xr, right_nz);
        }
        if (ms) {
            const inv = 1.0 / @sqrt(2.0);
            for (0..@min(is_from, 576)) |i| {
                const m = xr[0][i];
                const s = xr[1][i];
                xr[0][i] = (m + s) * inv;
                xr[1][i] = (m - s) * inv;
            }
        }
    }

    /// Интенсивное стерео; возвращает, с какой строки оно начинается (ниже — M/S).
    /// Для коротких блоков граница своя у каждого окна; M/S тогда применяется
    /// ко всему, что не попало под интенсивное (отмечено в `done`).
    fn intensityStereo(d: *Decoder, h: Header, gr: *const Granule, l: *const Layout, xr: *[2][576]f32, right_nz: usize) usize {
        _ = right_nz;
        const ms = h.ext & 2 != 0;
        const sf = &d.scf[1];
        // последняя ненулевая строка правого канала по записям раскладки
        var last_entry_nz: [3]i32 = .{ -1, -1, -1 }; // для коротких — по окнам; для длинных — [0]
        var start: usize = 0;
        var k: usize = 0;
        while (k < l.n) : (k += 1) {
            const w = l.w[k];
            var nz = false;
            for (start..start + w) |i| nz = nz or (i < 576 and xr[1][i] != 0);
            if (nz) {
                if (k < l.n_long) {
                    last_entry_nz = .{ @intCast(k), @intCast(k), @intCast(k) };
                } else {
                    const win = (k - l.n_long) % 3;
                    last_entry_nz[win] = @intCast(k);
                    // длинная часть смешанного блока целиком «занята»
                }
            }
            start += w;
        }
        var processed: [40]bool = .{false} ** 40;
        start = 0;
        k = 0;
        var first_is: usize = 576;
        while (k < l.n) : (k += 1) {
            const w = l.w[k];
            defer start += w;
            const win: usize = if (k < l.n_long) 0 else (k - l.n_long) % 3;
            if (@as(i32, @intCast(k)) <= last_entry_nz[win]) continue;
            if (l.n_long > 0 and k < l.n_long and l.n != l.n_long) {
                // длинная часть смешанного: интенсивное только если весь правый короткий ноль — упрощённо пропуск
                continue;
            }
            // значение позиции: для последней полосы — от предыдущей того же окна
            var src = k;
            const is_last = if (k < l.n_long) l.band[k] == 21 else l.band[k] == 12;
            if (is_last) src = if (k < l.n_long) k - 1 else k - 3;
            const pos: u32 = sf[src];
            var kl: f32 = 1;
            var kr: f32 = 1;
            if (h.ver == 0) {
                if (pos >= 7) continue;
                const t = std.math.tan(@as(f32, @floatFromInt(pos)) * std.math.pi / 12.0);
                kl = t / (1 + t);
                kr = 1 / (1 + t);
            } else {
                // группа, в которую попадает запись src
                var acc: usize = 0;
                var part: usize = 0;
                while (part < 4 and src >= acc + d.is_nr[part]) : (part += 1) acc += d.is_nr[part];
                if (part < 4 and pos == d.is_max[part] and d.is_max[part] != 0) continue;
                const io: f32 = if (gr.sfc & 1 != 0) 0.70710678 else 0.84089642;
                if (pos == 0) {} else if (pos & 1 == 1) {
                    kl = std.math.pow(f32, io, @floatFromInt((pos + 1) / 2));
                } else {
                    kr = std.math.pow(f32, io, @floatFromInt(pos / 2));
                }
            }
            for (start..@min(start + w, 576)) |i| {
                const v = xr[0][i];
                xr[0][i] = v * kl;
                xr[1][i] = v * kr;
            }
            processed[k] = true;
            first_is = @min(first_is, start);
        }
        if (!ms) return 576;
        // M/S для всего, что не интенсивное
        const inv = 1.0 / @sqrt(2.0);
        start = 0;
        k = 0;
        while (k < l.n) : (k += 1) {
            const w = l.w[k];
            if (!processed[k]) for (start..@min(start + w, 576)) |i| {
                const m = xr[0][i];
                const s = xr[1][i];
                xr[0][i] = (m + s) * inv;
                xr[1][i] = (m - s) * inv;
            };
            start += w;
        }
        return 0; // M/S уже сделано
    }

    fn hybrid(d: *Decoder, g: *const Granule, ch: usize, xr: *[576]f32, out: *[18][32]f32) void {
        for (0..32) |sb| {
            const x = xr[sb * 18 ..][0..18];
            var y: [36]f32 = undefined;
            const long = g.block_type != 2 or (g.mixed and sb < 2);
            if (long) {
                const bt: u2 = if (g.block_type == 2) 0 else g.block_type;
                imdct36(x, &y);
                for (0..36) |i| y[i] *= lwin[bt][i];
            } else {
                @memset(&y, 0);
                for (0..3) |w| {
                    var z: [12]f32 = undefined;
                    imdct12(x, w, &z);
                    for (0..12) |i| y[6 + 6 * w + i] += z[i] * win_short[i];
                }
            }
            const ov = &d.overlap[ch][sb];
            for (0..18) |i| {
                var v = y[i] + ov[i];
                if (sb & 1 == 1 and i & 1 == 1) v = -v;
                out[i][sb] = v;
                ov[i] = y[i + 18];
            }
        }
    }

    fn synthesize(d: *Decoder, ch: usize, s: *const [32]f32, pcm: *[32]f32) void {
        const st = &d.synth[ch];
        st.off = (st.off + 1024 - 64) % 1024;
        const v = st.v[st.off..][0..64];
        const n = getCos();
        for (0..64) |i| {
            var acc: f32 = 0;
            for (0..32) |k| acc += n[i][k] * s[k];
            v[i] = acc;
        }
        const dw = getWindow();
        for (0..32) |j| {
            var acc: f32 = 0;
            for (0..8) |i| {
                acc += st.v[(st.off + i * 128 + j) % 1024] * dw[i * 64 + j];
                acc += st.v[(st.off + i * 128 + 96 + j) % 1024] * dw[i * 64 + 32 + j];
            }
            pcm[j] = acc;
        }
    }
};

// ───────────── спектр ─────────────

/// Коды Хаффмана гранулы → целые значения; возвращает число строк до последней ненулевой.
fn huffman(r: *Bits, g: *const Granule, l: *const Layout, end_bit: usize, is: *[576]i32) usize {
    @memset(is, 0);
    const t = getTrees();
    // границы областей в строках
    var acc: usize = 0;
    var r1: usize = 576;
    var r2: usize = 576;
    var k: usize = 0;
    while (k < l.n) : (k += 1) {
        acc += l.w[k];
        if (k == g.region0) r1 = acc;
        if (k == g.region0 + g.region1 + 1) r2 = acc;
    }
    const bv = g.big_values * 2;
    var i: usize = 0;
    while (i < bv and i < 576) {
        const region: usize = if (i < r1) 0 else if (i < r2) 1 else 2;
        const ti = g.table[region];
        const tree = t.big[ti];
        if (tree == null) {
            i += 2;
            continue;
        }
        const xl = tab.big[ti].?.xlen;
        const lb: u5 = @intCast(tab.linbits[ti]);
        const sym = tree.?.decode(r);
        var x: i32 = @intCast(sym / xl);
        var y: i32 = @intCast(sym % xl);
        if (lb > 0 and x == 15) x += @intCast(r.get(lb));
        if (x != 0 and r.bit() == 1) x = -x;
        if (lb > 0 and y == 15) y += @intCast(r.get(lb));
        if (y != 0 and r.bit() == 1) y = -y;
        is[i] = x;
        is[i + 1] = y;
        i += 2;
    }
    const qt = t.quad[g.count1_table];
    while (i + 4 <= 576 and r.pos < end_bit) {
        const save = r.pos;
        const q = qt.decode(r);
        var vals: [4]i32 = .{ @intCast((q >> 3) & 1), @intCast((q >> 2) & 1), @intCast((q >> 1) & 1), @intCast(q & 1) };
        for (&vals) |*v| if (v.* != 0 and r.bit() == 1) {
            v.* = -v.*;
        };
        if (r.pos > end_bit) {
            r.pos = save;
            break;
        }
        for (0..4) |j| is[i + j] = vals[j];
        i += 4;
    }
    var last: usize = 0;
    for (0..576) |j| {
        if (is[j] != 0) last = j + 1;
    }
    return last;
}

var pow43_tab: [8207]f32 = undefined;
var pow43_ready = false;

fn pow43(v: i32) f32 {
    if (!pow43_ready) {
        for (&pow43_tab, 0..) |*p, i| p.* = std.math.pow(f32, @floatFromInt(i), 4.0 / 3.0);
        pow43_ready = true;
    }
    const a: u32 = @abs(v);
    const m = if (a < pow43_tab.len) pow43_tab[a] else std.math.pow(f32, @floatFromInt(a), 4.0 / 3.0);
    return if (v < 0) -m else m;
}

fn dequant(g: *const Granule, l: *const Layout, sf: *const [40]u8, is: *const [576]i32, xr: *[576]f32, mpeg1: bool) void {
    _ = mpeg1;
    const mult: i32 = if (g.sf_scale) 4 else 2;
    var start: usize = 0;
    for (0..l.n) |k| {
        const w = l.w[k];
        var q: i32 = @as(i32, @intCast(g.global_gain)) - 210;
        if (k < l.n_long) {
            const pt: i32 = if (g.preflag) pretab[l.band[k]] else 0;
            q -= mult * (@as(i32, sf[k]) + pt);
        } else {
            const win = (k - l.n_long) % 3;
            q -= 8 * @as(i32, g.subblock_gain[win]);
            q -= mult * @as(i32, sf[k]);
        }
        const scale = std.math.exp2(@as(f32, @floatFromInt(q)) * 0.25);
        for (start..@min(start + w, 576)) |i| xr[i] = if (is[i] == 0) 0 else pow43(is[i]) * scale;
        start += w;
    }
    for (start..576) |i| xr[i] = 0;
}

fn reorder(g: *const Granule, l: *const Layout, xr: *[576]f32) void {
    if (g.block_type != 2) return;
    var tmp: [576]f32 = xr.*;
    var start: usize = 0;
    var k: usize = 0;
    while (k < l.n_long) : (k += 1) start += l.w[k];
    // короткие: band start в строках (по одному окну) = start/3 относительно начала коротких
    const base = start;
    var f: usize = base / 3; // глобальный номер короткой частоты
    var pos = base;
    while (k + 2 < l.n) : (k += 3) {
        const w = l.w[k];
        for (0..3) |win| for (0..w) |j| {
            const dst = 3 * (f + j) + win;
            if (dst < 576 and pos < 576) tmp[dst] = xr[pos];
            pos += 1;
        };
        f += w;
    }
    xr.* = tmp;
}

const cs_ca = blk: {
    const c = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
    var cs: [8]f32 = undefined;
    var ca: [8]f32 = undefined;
    for (c, 0..) |v, i| {
        const sq = @sqrt(1.0 + v * v);
        cs[i] = @floatCast(1.0 / sq);
        ca[i] = @floatCast(v / sq);
    }
    break :blk .{ cs, ca };
};

fn antialias(g: *const Granule, xr: *[576]f32) void {
    if (g.block_type == 2 and !g.mixed) return;
    const sbs: usize = if (g.block_type == 2) 2 else 32;
    for (1..sbs) |sb| for (0..8) |i| {
        const a = xr[sb * 18 - 1 - i];
        const b = xr[sb * 18 + i];
        xr[sb * 18 - 1 - i] = a * cs_ca[0][i] - b * cs_ca[1][i];
        xr[sb * 18 + i] = b * cs_ca[0][i] + a * cs_ca[1][i];
    };
}

// ───────────── обратное МДКП и окна ─────────────

const lwin = blk: {
    @setEvalBranchQuota(100000);
    var w: [4][36]f32 = undefined;
    for (0..36) |i| {
        const fi: f64 = @floatFromInt(i);
        w[0][i] = @floatCast(@sin(std.math.pi / 36.0 * (fi + 0.5)));
        w[1][i] = if (i < 18) w[0][i] else if (i < 24) 1 else if (i < 30) @floatCast(@sin(std.math.pi / 12.0 * (fi - 18 + 0.5))) else 0;
        w[3][i] = if (i < 6) 0 else if (i < 12) @floatCast(@sin(std.math.pi / 12.0 * (fi - 6 + 0.5))) else if (i < 18) 1 else w[0][i];
        w[2][i] = 0;
    }
    break :blk w;
};

const win_short = blk: {
    var w: [12]f32 = undefined;
    for (0..12) |i| w[i] = @floatCast(@sin(std.math.pi / 12.0 * (@as(f64, @floatFromInt(i)) + 0.5)));
    break :blk w;
};

var cos36: [36][18]f32 = undefined;
var cos12: [12][6]f32 = undefined;
var cos_ready = false;

fn initCos() void {
    if (cos_ready) return;
    for (0..36) |i| for (0..18) |k| {
        const a = std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 1 + 18) * (2 * k + 1)));
        cos36[i][k] = @floatCast(@cos(a));
    };
    for (0..12) |i| for (0..6) |k| {
        const a = std.math.pi / 24.0 * @as(f64, @floatFromInt((2 * i + 1 + 6) * (2 * k + 1)));
        cos12[i][k] = @floatCast(@cos(a));
    };
    cos_ready = true;
}

fn imdct36(x: *const [18]f32, y: *[36]f32) void {
    initCos();
    for (0..36) |i| {
        var acc: f32 = 0;
        for (0..18) |k| acc += x[k] * cos36[i][k];
        y[i] = acc;
    }
}

fn imdct12(x: *const [18]f32, w: usize, z: *[12]f32) void {
    initCos();
    for (0..12) |i| {
        var acc: f32 = 0;
        for (0..6) |k| acc += x[3 * k + w] * cos12[i][k];
        z[i] = acc;
    }
}

// ───────────── синтез ─────────────

var syn_cos: [64][32]f32 = undefined;
var syn_win: [512]f32 = undefined;
var syn_ready = false;

fn initSynth() void {
    if (syn_ready) return;
    for (0..64) |i| for (0..32) |k| {
        const a = std.math.pi / 64.0 * @as(f64, @floatFromInt((16 + i) * (2 * k + 1)));
        syn_cos[i][k] = @floatCast(@cos(a));
    };
    syn_win = window();
    syn_ready = true;
}

fn getCos() *const [64][32]f32 {
    initSynth();
    return &syn_cos;
}
fn getWindow() *const [512]f32 {
    initSynth();
    return &syn_win;
}

/// Окно синтеза D[0..511] (ISO 11172-3, таблица 3-B.3) из половины в tab.enwindow.
pub fn window() [512]f32 {
    var w: [512]f32 = undefined;
    for (0..257) |i| {
        var v: i32 = tab.enwindow[i];
        w[i] = @as(f32, @floatFromInt(v)) / 65536.0;
        if (i & 63 != 0) v = -v;
        if (i != 0) w[512 - i] = @as(f32, @floatFromInt(v)) / 65536.0;
    }
    return w;
}

test "mp3: коды Хаффмана полны и префиксны" {
    for (tab.big) |h| {
        const t = h orelse continue;
        var kraft: f64 = 0;
        for (t.lens) |l| kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(l)));
        try std.testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-12);
    }
}

test "mp3: заголовок кадра" {
    const h = header(&.{ 0xFF, 0xFB, 0x90, 0x64 }).?; // MPEG-1 L3 128 кбит/с 44100 joint
    try std.testing.expectEqual(@as(u32, 128), h.bitrate);
    try std.testing.expectEqual(@as(u32, 44100), h.rate);
    try std.testing.expectEqual(@as(usize, 417), h.size);
    try std.testing.expectEqual(@as(u2, 1), h.mode);
}
