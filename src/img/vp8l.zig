//! WebP без потерь (VP8L, RFC 9649 §3–5): префиксные коды, обратные ссылки,
//! кэш цветов, мета-коды по областям и четыре преобразования (предсказание,
//! цвет, вычитание зелёного, палитра). Нужен и для альфа-канала WebP с
//! потерями (ALPH со сжатием 1 — тот же поток без заголовка).
//!
//! Разбор не доверяет входу: размеры проверяются до выделений, коды — по
//! полноте, ссылки — по границам; данных меньше — читаются нули, и время
//! ограничено числом пикселей.

const std = @import("std");

pub const Error = error{ Damaged, TooBig, OutOfMemory };

const Bits = struct {
    d: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    n: u7 = 0,

    fn fill(b: *Bits) void {
        while (b.n <= 56) {
            const byte: u64 = if (b.pos < b.d.len) b.d[b.pos] else 0;
            b.pos += 1;
            b.acc |= byte << @intCast(b.n);
            b.n += 8;
        }
    }

    fn read(b: *Bits, n: u6) u32 {
        if (n == 0) return 0;
        if (b.n < n) b.fill();
        const v: u32 = @intCast(b.acc & ((@as(u64, 1) << n) - 1));
        b.acc >>= n;
        b.n -= n;
        return v;
    }

    /// Прочитано больше, чем есть: поток кончился раньше картинки.
    fn over(b: *const Bits) bool {
        return b.pos > b.d.len + 8;
    }
};

// ───────────── префиксные коды ─────────────

const max_len = 15;

const Code = struct {
    /// один символ без битов (код из одного символа)
    single: ?u16 = null,
    count: [max_len + 1]u16 = [_]u16{0} ** (max_len + 1),
    symbols: []u16 = &.{},

    fn build(a: std.mem.Allocator, lengths: []const u8) Error!Code {
        var c = Code{};
        var nonzero: usize = 0;
        var last: u16 = 0;
        for (lengths, 0..) |l, s| if (l > 0) {
            if (l > max_len) return error.Damaged;
            c.count[l] += 1;
            nonzero += 1;
            last = @intCast(s);
        };
        if (nonzero == 0) return error.Damaged;
        if (nonzero == 1) {
            c.single = last;
            return c;
        }
        // полнота: сумма 2^-l ровно 1
        var left: i32 = 1;
        for (1..max_len + 1) |l| {
            left = left * 2 - c.count[l];
            if (left < 0) return error.Damaged;
        }
        if (left != 0) return error.Damaged;
        var offs: [max_len + 2]u16 = undefined;
        offs[1] = 0;
        for (1..max_len + 1) |l| offs[l + 1] = offs[l] + c.count[l];
        c.symbols = try a.alloc(u16, nonzero);
        for (lengths, 0..) |l, s| if (l > 0) {
            c.symbols[offs[l]] = @intCast(s);
            offs[l] += 1;
        };
        return c;
    }

    fn read(c: *const Code, b: *Bits) Error!u16 {
        if (c.single) |s| return s;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..max_len + 1) |l| {
            code |= @intCast(b.read(1));
            const cnt: i32 = c.count[l];
            if (code - cnt < first) return c.symbols[@intCast(index + (code - first))];
            index += cnt;
            first += cnt;
            first <<= 1;
            code <<= 1;
        }
        return error.Damaged;
    }
};

const order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

fn readCode(a: std.mem.Allocator, b: *Bits, alphabet: usize) Error!Code {
    const lengths = try a.alloc(u8, alphabet);
    @memset(lengths, 0);
    if (b.read(1) == 1) {
        // простой код: 1 или 2 символа
        const n = b.read(1) + 1;
        const first8 = b.read(1);
        const s0 = b.read(if (first8 == 1) 8 else 1);
        if (s0 >= alphabet) return error.Damaged;
        lengths[s0] = 1;
        if (n == 2) {
            const s1 = b.read(8);
            if (s1 >= alphabet) return error.Damaged;
            lengths[s1] = 1;
        }
        // один символ — ноль битов; два — по одному биту
        return Code.build(a, lengths);
    }
    var cl_lengths = [_]u8{0} ** 19;
    const n_cl = 4 + b.read(4);
    if (n_cl > 19) return error.Damaged;
    for (0..n_cl) |k| cl_lengths[order[k]] = @intCast(b.read(3));
    const cl = try Code.build(a, &cl_lengths);
    var max_symbol: usize = alphabet;
    if (b.read(1) == 1) {
        const nbits: u6 = @intCast(2 + 2 * b.read(3));
        max_symbol = 2 + b.read(nbits);
        if (max_symbol > alphabet) return error.Damaged;
    }
    var prev: u8 = 8;
    var s: usize = 0;
    while (s < alphabet) {
        if (max_symbol == 0) break;
        max_symbol -= 1;
        const v = try cl.read(b);
        if (v < 16) {
            lengths[s] = @intCast(v);
            s += 1;
            if (v != 0) prev = @intCast(v);
            continue;
        }
        const rep: usize = switch (v) {
            16 => 3 + b.read(2),
            17 => 3 + b.read(3),
            else => 11 + b.read(7),
        };
        if (s + rep > alphabet) return error.Damaged;
        const val: u8 = if (v == 16) prev else 0;
        @memset(lengths[s .. s + rep], val);
        s += rep;
    }
    return Code.build(a, lengths);
}

const Group = struct { codes: [5]Code };

fn readGroup(a: std.mem.Allocator, b: *Bits, cache_size: usize) Error!Group {
    var g: Group = undefined;
    const sizes = [5]usize{ 256 + 24 + cache_size, 256, 256, 256, 40 };
    for (sizes, 0..) |n, k| g.codes[k] = try readCode(a, b, n);
    return g;
}

// ───────────── пиксели ─────────────

const dist_map = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },  .{ -1, 2 }, .{ 2, 1 },  .{ -2, 1 },
    .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },  .{ 1, 3 },  .{ -1, 3 }, .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 },
    .{ 3, 2 },  .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },  .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 }, .{ 3, 3 },  .{ -3, 3 },
    .{ 2, 4 },  .{ -2, 4 }, .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },  .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },
    .{ 1, 5 },  .{ -1, 5 }, .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 }, .{ 4, 4 },  .{ -4, 4 },
    .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },  .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 },
    .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },  .{ -6, 2 }, .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 },
    .{ 6, 3 },  .{ -6, 3 }, .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },  .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 },
    .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 }, .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 }, .{ 3, 7 },  .{ -3, 7 },
    .{ 7, 3 },  .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 }, .{ 8, 0 },  .{ 4, 7 },  .{ -4, 7 }, .{ 7, 4 },
    .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },  .{ -6, 6 }, .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 },
    .{ 8, 4 },  .{ 6, 7 },  .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },  .{ 8, 7 },
};

fn prefixValue(b: *Bits, sym: u32) u32 {
    if (sym < 4) return sym + 1;
    const extra: u6 = @intCast((sym - 2) >> 1);
    const offset = (2 + (sym & 1)) << @intCast(extra);
    return offset + b.read(extra) + 1;
}

fn divRound(v: u32, bits: u5) u32 {
    return (v + (@as(u32, 1) << bits) - 1) >> bits;
}

/// Энтропийно кодированная картинка `w`×`h` (ARGB). `main` — основная картинка:
/// у неё бывают мета-коды по областям.
fn entropyImage(a: std.mem.Allocator, b: *Bits, w: u32, h: u32, main: bool) Error![]u32 {
    var cache_bits: u5 = 0;
    if (b.read(1) == 1) {
        const cb = b.read(4);
        if (cb < 1 or cb > 11) return error.Damaged;
        cache_bits = @intCast(cb);
    }
    const cache_size: usize = if (cache_bits > 0) @as(usize, 1) << cache_bits else 0;
    var meta_bits: u5 = 0;
    var meta: []u32 = &.{};
    var n_groups: usize = 1;
    if (main and b.read(1) == 1) {
        meta_bits = @intCast(b.read(3) + 2);
        const mw = divRound(w, meta_bits);
        const mh = divRound(h, meta_bits);
        meta = try entropyImage(a, b, mw, mh, false);
        for (meta) |*m| {
            m.* = (m.* >> 8) & 0xffff;
            n_groups = @max(n_groups, m.* + 1);
        }
        if (n_groups > 1 << 16) return error.Damaged;
    }
    const groups = try a.alloc(Group, n_groups);
    for (groups) |*g| g.* = try readGroup(a, b, cache_size);
    const cache = try a.alloc(u32, @max(cache_size, 1));
    @memset(cache, 0);
    const n: usize = @as(usize, w) * h;
    const px = try a.alloc(u32, n);
    var pos: usize = 0;
    const mw = if (meta_bits > 0) divRound(w, meta_bits) else 1;
    while (pos < n) {
        if (b.over()) return error.Damaged;
        const x: u32 = @intCast(pos % w);
        const y: u32 = @intCast(pos / w);
        const g = &groups[if (meta_bits > 0) meta[(y >> meta_bits) * mw + (x >> meta_bits)] else 0];
        const s = try g.codes[0].read(b);
        if (s < 256) {
            const r = try g.codes[1].read(b);
            const bl = try g.codes[2].read(b);
            const al = try g.codes[3].read(b);
            const argb = (@as(u32, al) << 24) | (@as(u32, r) << 16) | (@as(u32, s) << 8) | bl;
            px[pos] = argb;
            if (cache_bits > 0) cache[(0x1e35a7bd *% argb) >> @intCast(32 - @as(u6, cache_bits))] = argb;
            pos += 1;
        } else if (s < 256 + 24) {
            const len = prefixValue(b, s - 256);
            const ds = try g.codes[4].read(b);
            const dc = prefixValue(b, ds);
            var dist: i64 = undefined;
            if (dc > 120) {
                dist = dc - 120;
            } else {
                const m = dist_map[dc - 1];
                dist = @as(i64, m[0]) + @as(i64, m[1]) * w;
                if (dist < 1) dist = 1;
            }
            if (dist > pos or len > n - pos) return error.Damaged;
            const from = pos - @as(usize, @intCast(dist));
            for (0..len) |k| {
                const v = px[from + k];
                px[pos + k] = v;
                if (cache_bits > 0) cache[(0x1e35a7bd *% v) >> @intCast(32 - @as(u6, cache_bits))] = v;
            }
            pos += len;
        } else {
            const k = s - 256 - 24;
            if (k >= cache_size) return error.Damaged;
            const v = cache[k];
            px[pos] = v;
            if (cache_bits > 0) cache[(0x1e35a7bd *% v) >> @intCast(32 - @as(u6, cache_bits))] = v;
            pos += 1;
        }
    }
    return px;
}

// ───────────── преобразования ─────────────

const Transform = union(enum) {
    predict: struct { bits: u5, data: []u32 },
    color: struct { bits: u5, data: []u32 },
    green,
    palette: struct { bits: u5, colors: []u32, w: u32 },
};

fn ch(p: u32, comptime k: u5) u32 {
    return (p >> k) & 0xff;
}

fn add(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

fn avg2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) + (a & b);
}

fn clampAddSubFull(a: u32, b: u32, c: u32) u32 {
    var r: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |k| {
        const v = std.math.clamp(@as(i32, @intCast(ch(a, k))) + @as(i32, @intCast(ch(b, k))) - @as(i32, @intCast(ch(c, k))), 0, 255);
        r |= @as(u32, @intCast(v)) << k;
    }
    return r;
}

fn clampAddSubHalf(a: u32, b: u32) u32 {
    var r: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |k| {
        const x: i32 = @intCast(ch(a, k));
        const y: i32 = @intCast(ch(b, k));
        const v = std.math.clamp(x + @divTrunc(x - y, 2), 0, 255);
        r |= @as(u32, @intCast(v)) << k;
    }
    return r;
}

fn select(l: u32, t: u32, tl: u32) u32 {
    var pl: i32 = 0;
    var pt: i32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |k| {
        const p = @as(i32, @intCast(ch(l, k))) + @as(i32, @intCast(ch(t, k))) - @as(i32, @intCast(ch(tl, k)));
        pl += @intCast(@abs(p - @as(i32, @intCast(ch(l, k)))));
        pt += @intCast(@abs(p - @as(i32, @intCast(ch(t, k)))));
    }
    return if (pl < pt) l else t;
}

fn predictor(mode: u32, px: []const u32, pos: usize, w: u32) u32 {
    const l = px[pos - 1];
    const t = px[pos - w];
    const tl = px[pos - w - 1];
    const tr = px[pos - w + 1];
    return switch (mode) {
        0 => 0xff000000,
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => avg2(avg2(l, tr), t),
        6 => avg2(l, tl),
        7 => avg2(l, t),
        8 => avg2(tl, t),
        9 => avg2(t, tr),
        10 => avg2(avg2(l, tl), avg2(t, tr)),
        11 => select(l, t, tl),
        12 => clampAddSubFull(l, t, tl),
        13 => clampAddSubHalf(avg2(l, t), tl),
        else => 0xff000000, // 14, 15 — как 0 (запас кодировщика)
    };
}

fn delta(t: u32, c: u32) i32 {
    const ti: i8 = @bitCast(@as(u8, @intCast(t)));
    const ci: i8 = @bitCast(@as(u8, @intCast(c)));
    return (@as(i32, ti) * ci) >> 5;
}

fn inverse(tr: Transform, px: []u32, w: u32, h: u32, a: std.mem.Allocator) Error![]u32 {
    switch (tr) {
        .predict => |p| {
            const bw = divRound(w, p.bits);
            for (0..h) |y| for (0..w) |x| {
                const pos = y * w + x;
                const pred: u32 = if (y == 0 and x == 0) 0xff000000 else if (y == 0) px[pos - 1] else if (x == 0) px[pos - w] else blk: {
                    const mode = (p.data[(y >> p.bits) * bw + (x >> p.bits)] >> 8) & 0xf;
                    break :blk predictor(mode, px, pos, w);
                };
                px[pos] = add(px[pos], pred);
            };
            return px;
        },
        .color => |c| {
            const bw = divRound(w, c.bits);
            for (0..h) |y| for (0..w) |x| {
                const pos = y * w + x;
                const e = c.data[(y >> c.bits) * bw + (x >> c.bits)];
                const g2r = e & 0xff;
                const g2b = (e >> 8) & 0xff;
                const r2b = (e >> 16) & 0xff;
                const p = px[pos];
                const g = ch(p, 8);
                var r: i32 = @intCast(ch(p, 16));
                var bl: i32 = @intCast(ch(p, 0));
                r += delta(g2r, g);
                r &= 0xff;
                bl += delta(g2b, g);
                bl += delta(r2b, @intCast(r));
                bl &= 0xff;
                px[pos] = (p & 0xff00ff00) | (@as(u32, @intCast(r)) << 16) | @as(u32, @intCast(bl));
            };
            return px;
        },
        .green => {
            for (px) |*p| {
                const g = ch(p.*, 8);
                const r = (ch(p.*, 16) + g) & 0xff;
                const bl = (ch(p.*, 0) + g) & 0xff;
                p.* = (p.* & 0xff00ff00) | (r << 16) | bl;
            }
            return px;
        },
        .palette => |pl| {
            // px — упакованная картинка шириной pl.w; результат — w×h
            const out = try a.alloc(u32, @as(usize, w) * h);
            const per: u32 = @as(u32, 1) << pl.bits; // индексов в пикселе
            const ibits: u5 = @intCast(@as(u32, 8) >> pl.bits);
            const mask: u32 = (@as(u32, 1) << ibits) - 1;
            for (0..h) |y| for (0..w) |x| {
                const packed_ = px[y * pl.w + x / per];
                const shift: u5 = @intCast((x % per) * ibits);
                const idx = (ch(packed_, 8) >> shift) & mask;
                out[y * w + x] = if (idx < pl.colors.len) pl.colors[idx] else 0;
            };
            return out;
        },
    }
}

/// Поток VP8L без заголовка картинки `w`×`h`: преобразования и основная картинка → ARGB.
pub fn decodeStream(a: std.mem.Allocator, data: []const u8, w: u32, h: u32, max_pixels: u64) Error![]u32 {
    if (w == 0 or h == 0) return error.Damaged;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;
    var b = Bits{ .d = data };
    // у каждого преобразования — ширина картинки, к которой оно применено (палитра сужает следующие)
    var transforms: [4]Transform = undefined;
    var widths: [4]u32 = undefined;
    var n_tr: usize = 0;
    var seen: u4 = 0;
    var xs = w;
    while (b.read(1) == 1) {
        if (n_tr == 4) return error.Damaged;
        const kind: u2 = @intCast(b.read(2));
        const bit = @as(u4, 1) << kind;
        if (seen & bit != 0) return error.Damaged;
        seen |= bit;
        widths[n_tr] = xs;
        switch (kind) {
            0, 1 => {
                const bits: u5 = @intCast(b.read(3) + 2);
                const data_ = try entropyImage(a, &b, divRound(xs, bits), divRound(h, bits), false);
                transforms[n_tr] = if (kind == 0) .{ .predict = .{ .bits = bits, .data = data_ } } else .{ .color = .{ .bits = bits, .data = data_ } };
            },
            2 => transforms[n_tr] = .green,
            3 => {
                const n_colors = b.read(8) + 1;
                const colors = try entropyImage(a, &b, n_colors, 1, false);
                for (1..colors.len) |k| colors[k] = add(colors[k], colors[k - 1]);
                const bits: u5 = if (n_colors <= 2) 3 else if (n_colors <= 4) 2 else if (n_colors <= 16) 1 else 0;
                transforms[n_tr] = .{ .palette = .{ .bits = bits, .colors = colors, .w = divRound(xs, bits) } };
                xs = divRound(xs, bits);
            },
        }
        n_tr += 1;
    }
    var px = try entropyImage(a, &b, xs, h, true);
    // обратные — в обратном порядке; палитра разворачивает упакованную ширину в свою
    var k = n_tr;
    while (k > 0) {
        k -= 1;
        px = try inverse(transforms[k], px, widths[k], h, a);
    }
    return px;
}

/// Заголовок VP8L: подпись 0x2f, ширина и высота по 14 бит, альфа, версия 0.
pub fn header(data: []const u8) ?struct { w: u32, h: u32, alpha: bool } {
    if (data.len < 5 or data[0] != 0x2f) return null;
    const v = std.mem.readInt(u32, data[1..5], .little);
    if (v >> 29 != 0) return null;
    return .{ .w = (v & 0x3fff) + 1, .h = ((v >> 14) & 0x3fff) + 1, .alpha = (v >> 28) & 1 != 0 };
}

/// Полный поток VP8L (с заголовком) → ARGB.
pub fn decode(a: std.mem.Allocator, data: []const u8, max_pixels: u64) Error!struct { w: u32, h: u32, argb: []u32 } {
    const h = header(data) orelse return error.Damaged;
    return .{ .w = h.w, .h = h.h, .argb = try decodeStream(a, data[5..], h.w, h.h, max_pixels) };
}

test "vp8l: таблица расстояний полна" {
    try std.testing.expectEqual(@as(usize, 120), dist_map.len);
}
