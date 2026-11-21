//! WebP с потерями: ключевой кадр VP8 (RFC 6386) → плоскости Y, U, V.
//! Булев декодер, заголовок кадра (сегменты, фильтр, квантователи, обновление
//! вероятностей), режимы макроблоков, остатки по разделам, обратные WHT и ДКП,
//! внутрикадровое предсказание 16×16, 4×4 и 8×8 и петлевой фильтр (простой и
//! обычный). Порядок и числа — как в libwebp, чтобы картинка совпадала с тем,
//! что показывают браузеры.
//!
//! Разбор не доверяет входу: размеры и разделы проверяются, булев декодер за
//! концом данных читает нули — время ограничено числом макроблоков.

const std = @import("std");
const T = @import("vp8_tables.zig");

pub const Error = error{ Damaged, TooBig, Unsupported, OutOfMemory };

pub const Frame = struct {
    w: u32,
    h: u32,
    /// плоскости с шагом в целое число макроблоков
    y: []u8,
    u: []u8,
    v: []u8,
    y_stride: usize,
    uv_stride: usize,
};

// ───────────── булев декодер ─────────────

const Bool = struct {
    d: []const u8,
    pos: usize = 0,
    value: u32 = 0,
    /// диапазон минус один, как в libwebp: [127, 254]
    range: u32 = 254,
    bits: i32 = -8,

    fn init(d: []const u8) Bool {
        var b = Bool{ .d = d };
        b.load();
        return b;
    }

    fn load(b: *Bool) void {
        while (b.bits < 0) {
            const byte: u32 = if (b.pos < b.d.len) b.d[b.pos] else 0;
            b.pos += 1;
            b.value = (b.value << 8) | byte;
            b.bits += 8;
        }
    }

    fn get(b: *Bool, prob: u32) u1 {
        const split = (b.range * prob) >> 8;
        var bit: u1 = 0;
        if ((b.value >> @intCast(b.bits)) > split) {
            b.range -= split + 1;
            b.value -= (split + 1) << @intCast(b.bits);
            bit = 1;
        } else {
            b.range = split;
        }
        // нормализация: range в [127, 254]
        while (b.range < 127) {
            b.range = (b.range << 1) | 1;
            b.bits -= 1;
            if (b.bits < 0) b.load();
        }
        return bit;
    }

    fn lit(b: *Bool, n: u5) u32 {
        var v: u32 = 0;
        var k = n;
        while (k > 0) : (k -= 1) v = (v << 1) | b.get(0x80);
        return v;
    }

    fn signed(b: *Bool, n: u5) i32 {
        const v: i32 = @intCast(b.lit(n));
        return if (b.get(0x80) == 1) -v else v;
    }

    /// Флаг и за ним знаковое значение (или 0).
    fn opt(b: *Bool, n: u5) i32 {
        return if (b.get(0x80) == 1) b.signed(n) else 0;
    }
};

// ───────────── заголовок ─────────────

const Quant = struct { y1: [2]i32, y2: [2]i32, uv: [2]i32 };
const Filter = struct { limit: i32 = 0, ilevel: i32 = 0, hev: i32 = 0, inner: bool = false };

const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const cat3 = [_]u8{ 173, 148, 140 };
const cat4 = [_]u8{ 176, 155, 140, 135 };
const cat5 = [_]u8{ 180, 157, 141, 134, 130 };
const cat6 = [_]u8{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 };
const cats = [4][]const u8{ &cat3, &cat4, &cat5, &cat6 };

// режимы 4×4 в порядке libwebp; 16×16 и цветность — те же номера (DC, TM, VE, HE)
const B_DC = 0;
const B_TM = 1;
const B_VE = 2;
const B_HE = 3;
const B_RD = 4;
const B_VR = 5;
const B_LD = 6;
const B_VL = 7;
const B_HD = 8;
const B_HU = 9;

const Dec = struct {
    a: std.mem.Allocator,
    mbw: usize,
    mbh: usize,
    probs: [4][8][3][11]u8,
    seg_on: bool = false,
    seg_update_map: bool = false,
    seg_abs: bool = false,
    seg_q: [4]i32 = .{ 0, 0, 0, 0 },
    seg_lf: [4]i32 = .{ 0, 0, 0, 0 },
    seg_probs: [3]u8 = .{ 255, 255, 255 },
    simple: bool = false,
    level: i32 = 0,
    sharpness: i32 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i32 = .{ 0, 0, 0, 0 },
    mode_lf_delta: [4]i32 = .{ 0, 0, 0, 0 },
    quant: [4]Quant = undefined,
    skip_prob: ?u8 = null,
    parts: [8]Bool = undefined,
    n_parts: usize = 1,
    // контексты: режимы 4×4 сверху (по 4 на макроблок) и слева
    top_modes: []u8 = &.{},
    left_modes: [4]u8 = .{ 0, 0, 0, 0 },
    // ненулевые блоки: сверху по макроблоку (y 4, u 2, v 2, dc 1) и слева
    top_nz: [][9]u1 = &.{},
    left_nz: [9]u1 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

fn clip(v: i32, hi: i32) i32 {
    return std.math.clamp(v, 0, hi);
}

pub fn size(data: []const u8) ?[2]u32 {
    if (data.len < 10 or data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return null;
    return .{ std.mem.readInt(u16, data[6..8], .little) & 0x3fff, std.mem.readInt(u16, data[8..10], .little) & 0x3fff };
}

pub fn decode(a: std.mem.Allocator, data: []const u8, max_pixels: u64) Error!Frame {
    if (data.len < 10) return error.Damaged;
    const tag = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    if (tag & 1 != 0) return error.Unsupported; // не ключевой кадр
    if ((tag >> 1) & 7 > 3) return error.Unsupported;
    const part0 = tag >> 5;
    const wh = size(data) orelse return error.Damaged;
    const w = wh[0];
    const h = wh[1];
    if (w == 0 or h == 0) return error.Damaged;
    if (@as(u64, w) * h > max_pixels) return error.TooBig;
    var rest = data[10..];
    if (part0 > rest.len) return error.Damaged;
    var br = Bool.init(rest[0..part0]);
    rest = rest[part0..];

    var dec = Dec{ .a = a, .mbw = (w + 15) / 16, .mbh = (h + 15) / 16, .probs = undefined };
    @memcpy(std.mem.asBytes(&dec.probs), &T.coeffs);
    _ = br.get(0x80); // цветовое пространство
    _ = br.get(0x80); // ограничение
    dec.seg_on = br.get(0x80) == 1;
    if (dec.seg_on) {
        dec.seg_update_map = br.get(0x80) == 1;
        if (br.get(0x80) == 1) { // данные сегментов
            dec.seg_abs = br.get(0x80) == 1;
            for (&dec.seg_q) |*q| q.* = br.opt(7);
            for (&dec.seg_lf) |*l| l.* = br.opt(6);
        }
        if (dec.seg_update_map) for (&dec.seg_probs) |*p| {
            p.* = if (br.get(0x80) == 1) @intCast(br.lit(8)) else 255;
        };
    }
    dec.simple = br.get(0x80) == 1;
    dec.level = @intCast(br.lit(6));
    dec.sharpness = @intCast(br.lit(3));
    dec.use_lf_delta = br.get(0x80) == 1;
    if (dec.use_lf_delta and br.get(0x80) == 1) {
        for (&dec.ref_lf_delta) |*d| {
            if (br.get(0x80) == 1) d.* = br.signed(6);
        }
        for (&dec.mode_lf_delta) |*d| {
            if (br.get(0x80) == 1) d.* = br.signed(6);
        }
    }
    // разделы остатков: размеры (кроме последнего) — по 3 байта
    dec.n_parts = @as(usize, 1) << @intCast(br.lit(2));
    {
        const sizes_len = 3 * (dec.n_parts - 1);
        if (rest.len < sizes_len) return error.Damaged;
        var off: usize = sizes_len;
        for (0..dec.n_parts) |p| {
            var psize: usize = rest.len - off;
            if (p + 1 < dec.n_parts) {
                const s = rest[p * 3 ..][0..3];
                psize = @as(usize, s[0]) | (@as(usize, s[1]) << 8) | (@as(usize, s[2]) << 16);
                if (psize > rest.len - off) psize = rest.len - off;
            }
            dec.parts[p] = Bool.init(rest[off..][0..psize]);
            off += psize;
        }
    }
    // квантователи
    const base_q: i32 = @intCast(br.lit(7));
    const dqy1_dc = br.opt(4);
    const dqy2_dc = br.opt(4);
    const dqy2_ac = br.opt(4);
    const dquv_dc = br.opt(4);
    const dquv_ac = br.opt(4);
    for (0..4) |s| {
        var q = base_q;
        if (dec.seg_on) q = if (dec.seg_abs) dec.seg_q[s] else q + dec.seg_q[s];
        const qy = &dec.quant[s];
        qy.y1 = .{ T.dc[@intCast(clip(q + dqy1_dc, 127))], T.ac[@intCast(clip(q, 127))] };
        qy.y2 = .{ @as(i32, T.dc[@intCast(clip(q + dqy2_dc, 127))]) * 2, @divTrunc(@as(i32, T.ac[@intCast(clip(q + dqy2_ac, 127))]) * 101581, 1 << 16) };
        if (qy.y2[1] < 8) qy.y2[1] = 8;
        qy.uv = .{ T.dc[@intCast(clip(q + dquv_dc, 117))], T.ac[@intCast(clip(q + dquv_ac, 127))] };
    }
    _ = br.get(0x80); // обновлять ли вероятности (для одного кадра неважно)
    for (0..4) |t| for (0..8) |b| for (0..3) |c| for (0..11) |p| {
        if (br.get(T.update[((t * 8 + b) * 3 + c) * 11 + p]) == 1) dec.probs[t][b][c][p] = @intCast(br.lit(8));
    };
    if (br.get(0x80) == 1) dec.skip_prob = @intCast(br.lit(8));

    // плоскости с полем под целые макроблоки
    const ys = dec.mbw * 16;
    const uvs = dec.mbw * 8;
    const yp = try a.alloc(u8, ys * dec.mbh * 16);
    errdefer a.free(yp);
    const up = try a.alloc(u8, uvs * dec.mbh * 8);
    errdefer a.free(up);
    const vp = try a.alloc(u8, uvs * dec.mbh * 8);
    errdefer a.free(vp);
    dec.top_modes = try a.alloc(u8, dec.mbw * 4);
    defer a.free(dec.top_modes);
    @memset(dec.top_modes, B_DC);
    dec.top_nz = try a.alloc([9]u1, dec.mbw);
    defer a.free(dec.top_nz);
    @memset(dec.top_nz, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    const filters = try a.alloc(Filter, dec.mbw * dec.mbh);
    defer a.free(filters);

    for (0..dec.mbh) |my| {
        dec.left_modes = .{ B_DC, B_DC, B_DC, B_DC };
        dec.left_nz = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const tb = &dec.parts[my & (dec.n_parts - 1)];
        for (0..dec.mbw) |mx| {
            try macroblock(&dec, &br, tb, mx, my, yp, up, vp, ys, uvs, &filters[my * dec.mbw + mx]);
        }
    }
    if (dec.level > 0) loopFilter(&dec, filters, yp, up, vp, ys, uvs);
    return .{ .w = w, .h = h, .y = yp, .u = up, .v = vp, .y_stride = ys, .uv_stride = uvs };
}

// ───────────── макроблок ─────────────

fn macroblock(dec: *Dec, br: *Bool, tb: *Bool, mx: usize, my: usize, yp: []u8, up: []u8, vp: []u8, ys: usize, uvs: usize, filt: *Filter) Error!void {
    var seg: usize = 0;
    if (dec.seg_update_map) {
        seg = if (br.get(dec.seg_probs[0]) == 0) br.get(dec.seg_probs[1]) else 2 + @as(usize, br.get(dec.seg_probs[2]));
    }
    var skip = if (dec.skip_prob) |p| br.get(p) == 1 else false;
    // режим яркости
    const is4 = br.get(145) == 0;
    var ymode: u8 = B_DC;
    var sub: [16]u8 = undefined;
    if (!is4) {
        ymode = if (br.get(156) == 0) (if (br.get(163) == 0) B_DC else B_VE) else (if (br.get(128) == 0) B_HE else B_TM);
        @memset(&sub, ymode);
        for (0..4) |k| {
            dec.top_modes[mx * 4 + k] = ymode;
            dec.left_modes[k] = ymode;
        }
    } else {
        for (0..4) |y| {
            var left = dec.left_modes[y];
            for (0..4) |x| {
                const top = dec.top_modes[mx * 4 + x];
                const p = T.bmodes[(@as(usize, top) * 10 + left) * 9 ..][0..9];
                // дерево режимов 4×4
                const m: u8 = if (br.get(p[0]) == 0) B_DC else if (br.get(p[1]) == 0) B_TM else if (br.get(p[2]) == 0) B_VE else if (br.get(p[3]) == 0)
                    (if (br.get(p[4]) == 0) B_HE else if (br.get(p[5]) == 0) B_RD else B_VR)
                else if (br.get(p[6]) == 0) B_LD else if (br.get(p[7]) == 0) B_VL else if (br.get(p[8]) == 0) B_HD else B_HU;
                sub[y * 4 + x] = m;
                dec.top_modes[mx * 4 + x] = m;
                left = m;
            }
            dec.left_modes[y] = left;
        }
    }
    const uvmode: u8 = if (br.get(142) == 0) B_DC else if (br.get(114) == 0) B_VE else if (br.get(183) == 0) B_HE else B_TM;

    // остатки
    var coeffs: [24 * 16]i16 = undefined;
    @memset(&coeffs, 0);
    var nz_y: u16 = 0; // ненулевые блоки 4×4 яркости
    var nz_uv: u8 = 0;
    const q = dec.quant[seg];
    const tnz = &dec.top_nz[mx];
    const lnz = &dec.left_nz;
    if (!skip) {
        var first: usize = 0;
        var ac_type: usize = 3;
        if (!is4) {
            var dc: [16]i16 = .{0} ** 16;
            const ctx = @as(usize, tnz[8]) + lnz[8];
            const n = try coefs(dec, tb, 1, ctx, q.y2, 0, &dc);
            tnz[8] = @intFromBool(n > 0);
            lnz[8] = tnz[8];
            if (n > 1) {
                wht(&dc, &coeffs);
            } else {
                const dc0: i16 = @intCast((@as(i32, dc[0]) + 3) >> 3);
                for (0..16) |k| coeffs[k * 16] = dc0;
            }
            first = 1;
            ac_type = 0;
        }
        for (0..4) |y| for (0..4) |x| {
            const ctx = @as(usize, tnz[x]) + lnz[y];
            const blk = coeffs[(y * 4 + x) * 16 ..][0..16];
            const n = try coefs(dec, tb, ac_type, ctx, q.y1, first, blk);
            const nzb = @intFromBool(n > first);
            tnz[x] = nzb;
            lnz[y] = nzb;
            if (n > 0 or blk[0] != 0) nz_y |= @as(u16, 1) << @intCast(y * 4 + x);
        };
        for (0..2) |c| for (0..2) |y| for (0..2) |x| {
            const ti = 4 + c * 2 + x;
            const li = 4 + c * 2 + y;
            const ctx = @as(usize, tnz[ti]) + lnz[li];
            const k = 16 + c * 4 + y * 2 + x;
            const n = try coefs(dec, tb, 2, ctx, q.uv, 0, coeffs[k * 16 ..][0..16]);
            const nzb = @intFromBool(n > 0);
            tnz[ti] = nzb;
            lnz[li] = nzb;
            if (n > 0) nz_uv |= @as(u8, 1) << @intCast(c * 4 + y * 2 + x);
        };
        if (nz_y == 0 and nz_uv == 0) skip = true;
    } else {
        for (0..8) |k| {
            tnz[k] = 0;
            lnz[k] = 0;
        }
        if (!is4) {
            tnz[8] = 0;
            lnz[8] = 0;
        }
    }

    // сила фильтра
    if (dec.level > 0) {
        var level = dec.level;
        if (dec.seg_on) level = if (dec.seg_abs) dec.seg_lf[seg] else level + dec.seg_lf[seg];
        if (dec.use_lf_delta) {
            level += dec.ref_lf_delta[0];
            if (is4) level += dec.mode_lf_delta[0];
        }
        level = clip(level, 63);
        if (level > 0) {
            var il = level;
            if (dec.sharpness > 0) {
                il >>= if (dec.sharpness > 4) 2 else 1;
                if (il > 9 - dec.sharpness) il = 9 - dec.sharpness;
            }
            if (il < 1) il = 1;
            filt.* = .{ .limit = 2 * level + il, .ilevel = il, .hev = if (level >= 40) 2 else if (level >= 15) 1 else 0, .inner = is4 or !skip };
        } else filt.* = .{};
    } else filt.* = .{};

    reconstruct(mx, my, dec.mbw, is4, ymode, &sub, uvmode, &coeffs, yp, up, vp, ys, uvs);
}

fn coefs(dec: *Dec, b: *Bool, t: usize, ctx0: usize, dq: [2]i32, first: usize, out: []i16) Error!usize {
    var n = first;
    var p = &dec.probs[t][bands[n]][ctx0];
    while (n < 16) {
        if (b.get(p[0]) == 0) return n; // конец блока
        while (b.get(p[1]) == 0) { // нули
            n += 1;
            if (n == 16) return 16;
            p = &dec.probs[t][bands[n]][0];
        }
        var v: i32 = undefined;
        var next_ctx: usize = undefined;
        if (b.get(p[2]) == 0) {
            v = 1;
            next_ctx = 1;
        } else {
            if (b.get(p[3]) == 0) {
                v = if (b.get(p[4]) == 0) 2 else 3 + @as(i32, b.get(p[5]));
            } else if (b.get(p[6]) == 0) {
                if (b.get(p[7]) == 0) {
                    v = 5 + @as(i32, b.get(159));
                } else {
                    v = 7 + 2 * @as(i32, b.get(165));
                    v += b.get(145);
                }
            } else {
                const b1 = b.get(p[8]);
                const b0 = b.get(p[9 + @as(usize, b1)]);
                const cat = 2 * @as(usize, b1) + b0;
                v = 0;
                for (cats[cat]) |pr| v = v + v + b.get(pr);
                v += 3 + (@as(i32, 8) << @intCast(cat));
            }
            next_ctx = 2;
        }
        if (b.get(0x80) == 1) v = -v;
        out[zigzag[n]] = @intCast(std.math.clamp(v * dq[@intFromBool(n > 0)], -32768, 32767));
        n += 1;
        if (n == 16) return 16;
        p = &dec.probs[t][bands[n]][next_ctx];
    }
    return 16;
}

fn wht(in: *const [16]i16, out: *[24 * 16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[(i * 4 + 0) * 16] = @intCast(std.math.clamp((a0 + a1) >> 3, -32768, 32767));
        out[(i * 4 + 1) * 16] = @intCast(std.math.clamp((a3 + a2) >> 3, -32768, 32767));
        out[(i * 4 + 2) * 16] = @intCast(std.math.clamp((a0 - a1) >> 3, -32768, 32767));
        out[(i * 4 + 3) * 16] = @intCast(std.math.clamp((a3 - a2) >> 3, -32768, 32767));
    }
}

fn mul1(a: i32) i32 {
    return ((a * 20091) >> 16) + a;
}
fn mul2(a: i32) i32 {
    return (a * 35468) >> 16;
}

/// Обратное ДКП 4×4 с прибавлением к предсказанию (dst — 4×4 с шагом bps).
fn idct(in: *const [16]i16, dst: []u8, stride: usize) void {
    var c: [16]i32 = undefined;
    for (0..4) |i| {
        const a = @as(i32, in[0 + i]) + in[8 + i];
        const b = @as(i32, in[0 + i]) - in[8 + i];
        const cc = mul2(in[4 + i]) - mul1(in[12 + i]);
        const d = mul1(in[4 + i]) + mul2(in[12 + i]);
        c[i * 4 + 0] = a + d;
        c[i * 4 + 1] = b + cc;
        c[i * 4 + 2] = b - cc;
        c[i * 4 + 3] = a - d;
    }
    for (0..4) |i| {
        const dc = c[0 + i] + 4;
        const a = dc + c[8 + i];
        const b = dc - c[8 + i];
        const cc = mul2(c[4 + i]) - mul1(c[12 + i]);
        const d = mul1(c[4 + i]) + mul2(c[12 + i]);
        const row = dst[i * stride ..];
        inline for (.{ a + d, b + cc, b - cc, a - d }, 0..) |v, x| {
            row[x] = @intCast(clip(@as(i32, row[x]) + (v >> 3), 255));
        }
    }
}

// ───────────── предсказание ─────────────

const bps = 32;

fn avg3(a: u8, b: u8, c: u8) u8 {
    return @intCast((@as(u32, a) + 2 * @as(u32, b) + c + 2) >> 2);
}
fn avg2(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) + b + 1) >> 1);
}

/// Предсказание блока n×n в рабочем буфере (верх — buf[off-bps], лево — buf[off-1]).
fn predictBig(buf: []u8, off: usize, n: usize, mode: u8, has_top: bool, has_left: bool) void {
    switch (mode) {
        B_DC => {
            var s: u32 = 0;
            var shift: u5 = 0;
            if (has_top) {
                for (0..n) |x| s += buf[off - bps + x];
                shift += 1;
            }
            if (has_left) {
                for (0..n) |y| s += buf[off + y * bps - 1];
                shift += 1;
            }
            const lg: u5 = if (n == 16) 4 else 3;
            const v: u8 = if (shift == 0) 0x80 else @intCast((s + (@as(u32, 1) << (lg + shift - 2))) >> (lg + shift - 1));
            for (0..n) |y| @memset(buf[off + y * bps ..][0..n], v);
        },
        B_TM => {
            const tl: i32 = buf[off - bps - 1];
            for (0..n) |y| {
                const l: i32 = buf[off + y * bps - 1];
                for (0..n) |x| buf[off + y * bps + x] = @intCast(clip(l + buf[off - bps + x] - tl, 255));
            }
        },
        B_VE => for (0..n) |y| @memcpy(buf[off + y * bps ..][0..n], buf[off - bps ..][0..n]),
        else => for (0..n) |y| @memset(buf[off + y * bps ..][0..n], buf[off + y * bps - 1]),
    }
}

fn predict4(buf: []u8, off: usize, mode: u8) void {
    const top = buf[off - bps ..][0..8];
    const X = buf[off - bps - 1];
    const I = buf[off - 1];
    const J = buf[off + bps - 1];
    const K = buf[off + 2 * bps - 1];
    const L = buf[off + 3 * bps - 1];
    const A = top[0];
    const B = top[1];
    const C = top[2];
    const D = top[3];
    const E = top[4];
    const F = top[5];
    const G = top[6];
    const H = top[7];
    var o: [4][4]u8 = undefined; // [y][x]
    switch (mode) {
        B_DC => {
            var s: u32 = 4;
            for (0..4) |k| s += @as(u32, top[k]) + buf[off + k * bps - 1];
            const v: u8 = @intCast(s >> 3);
            o = .{ .{ v, v, v, v }, .{ v, v, v, v }, .{ v, v, v, v }, .{ v, v, v, v } };
        },
        B_TM => {
            for (0..4) |y| for (0..4) |x| {
                o[y][x] = @intCast(clip(@as(i32, buf[off + y * bps - 1]) + top[x] - X, 255));
            };
        },
        B_VE => {
            const r = [4]u8{ avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E) };
            o = .{ r, r, r, r };
        },
        B_HE => {
            const r = [4]u8{ avg3(X, I, J), avg3(I, J, K), avg3(J, K, L), avg3(K, L, L) };
            for (0..4) |y| o[y] = .{ r[y], r[y], r[y], r[y] };
        },
        B_RD => {
            o[3][0] = avg3(J, K, L);
            o[3][1] = avg3(I, J, K);
            o[2][0] = o[3][1];
            o[3][2] = avg3(X, I, J);
            o[2][1] = o[3][2];
            o[1][0] = o[3][2];
            o[3][3] = avg3(A, X, I);
            o[2][2] = o[3][3];
            o[1][1] = o[3][3];
            o[0][0] = o[3][3];
            o[2][3] = avg3(B, A, X);
            o[1][2] = o[2][3];
            o[0][1] = o[2][3];
            o[1][3] = avg3(C, B, A);
            o[0][2] = o[1][3];
            o[0][3] = avg3(D, C, B);
        },
        B_LD => {
            o[0][0] = avg3(A, B, C);
            o[0][1] = avg3(B, C, D);
            o[1][0] = o[0][1];
            o[0][2] = avg3(C, D, E);
            o[1][1] = o[0][2];
            o[2][0] = o[0][2];
            o[0][3] = avg3(D, E, F);
            o[1][2] = o[0][3];
            o[2][1] = o[0][3];
            o[3][0] = o[0][3];
            o[1][3] = avg3(E, F, G);
            o[2][2] = o[1][3];
            o[3][1] = o[1][3];
            o[2][3] = avg3(F, G, H);
            o[3][2] = o[2][3];
            o[3][3] = avg3(G, H, H);
        },
        B_VR => {
            o[0][0] = avg2(X, A);
            o[2][1] = o[0][0];
            o[0][1] = avg2(A, B);
            o[2][2] = o[0][1];
            o[0][2] = avg2(B, C);
            o[2][3] = o[0][2];
            o[0][3] = avg2(C, D);
            o[3][0] = avg3(K, J, I);
            o[2][0] = avg3(J, I, X);
            o[1][0] = avg3(I, X, A);
            o[3][1] = o[1][0];
            o[1][1] = avg3(X, A, B);
            o[3][2] = o[1][1];
            o[1][2] = avg3(A, B, C);
            o[3][3] = o[1][2];
            o[1][3] = avg3(B, C, D);
        },
        B_VL => {
            o[0][0] = avg2(A, B);
            o[0][1] = avg2(B, C);
            o[2][0] = o[0][1];
            o[0][2] = avg2(C, D);
            o[2][1] = o[0][2];
            o[0][3] = avg2(D, E);
            o[2][2] = o[0][3];
            o[1][0] = avg3(A, B, C);
            o[1][1] = avg3(B, C, D);
            o[3][0] = o[1][1];
            o[1][2] = avg3(C, D, E);
            o[3][1] = o[1][2];
            o[1][3] = avg3(D, E, F);
            o[3][2] = o[1][3];
            o[2][3] = avg3(E, F, G);
            o[3][3] = avg3(F, G, H);
        },
        B_HU => {
            o[0][0] = avg2(I, J);
            o[0][2] = avg2(J, K);
            o[1][0] = o[0][2];
            o[1][2] = avg2(K, L);
            o[2][0] = o[1][2];
            o[0][1] = avg3(I, J, K);
            o[0][3] = avg3(J, K, L);
            o[1][1] = o[0][3];
            o[1][3] = avg3(K, L, L);
            o[2][1] = o[1][3];
            o[2][3] = L;
            o[2][2] = L;
            o[3] = .{ L, L, L, L };
        },
        else => { // B_HD
            o[0][0] = avg2(I, X);
            o[1][2] = o[0][0];
            o[1][0] = avg2(J, I);
            o[2][2] = o[1][0];
            o[2][0] = avg2(K, J);
            o[3][2] = o[2][0];
            o[3][0] = avg2(L, K);
            o[0][3] = avg3(A, B, C);
            o[0][2] = avg3(X, A, B);
            o[0][1] = avg3(I, X, A);
            o[1][3] = o[0][1];
            o[1][1] = avg3(J, I, X);
            o[2][3] = o[1][1];
            o[2][1] = avg3(K, J, I);
            o[3][3] = o[2][1];
            o[3][1] = avg3(L, K, J);
        },
    }
    for (0..4) |y| @memcpy(buf[off + y * bps ..][0..4], &o[y]);
}

/// Восстановление макроблока: рабочий буфер с краями (как в libwebp), затем — в плоскости.
fn reconstruct(mx: usize, my: usize, mbw: usize, is4: bool, ymode: u8, sub: *const [16]u8, uvmode: u8, coeffs: *const [24 * 16]i16, yp: []u8, up: []u8, vp: []u8, ys: usize, uvs: usize) void {
    // Y: строки 0..16 (0 — верх), столбцы 0..20 (0 — лево, 17..20 — верх-право)
    var yb: [17 * bps]u8 = undefined;
    const yo = bps + 1;
    // верх
    if (my > 0) {
        @memcpy(yb[1..17], yp[(my * 16 - 1) * ys + mx * 16 ..][0..16]);
        yb[0] = if (mx > 0) yp[(my * 16 - 1) * ys + mx * 16 - 1] else 129;
        if (mx + 1 < mbw) {
            @memcpy(yb[17..21], yp[(my * 16 - 1) * ys + mx * 16 + 16 ..][0..4]);
        } else @memset(yb[17..21], yp[(my * 16 - 1) * ys + mx * 16 + 15]);
    } else @memset(yb[0..21], 127);
    // лево
    for (0..16) |y| yb[yo + y * bps - 1] = if (mx > 0) yp[(my * 16 + y) * ys + mx * 16 - 1] else 129;
    // верх-право повторяется над строками 4×4 ниже первой
    for (1..4) |r| @memcpy(yb[yo + (r * 4 - 1) * bps + 16 ..][0..4], yb[17..21]);
    if (is4) {
        for (0..16) |k| {
            const off = yo + (k / 4) * 4 * bps + (k % 4) * 4;
            predict4(&yb, off, sub[k]);
            idct(coeffs[k * 16 ..][0..16], yb[off..], bps);
        }
    } else {
        predictBig(&yb, yo, 16, ymode, my > 0, mx > 0);
        for (0..16) |k| idct(coeffs[k * 16 ..][0..16], yb[yo + (k / 4) * 4 * bps + (k % 4) * 4 ..], bps);
    }
    for (0..16) |y| @memcpy(yp[(my * 16 + y) * ys + mx * 16 ..][0..16], yb[yo + y * bps ..][0..16]);
    // U, V
    for ([2][]u8{ up, vp }, 0..) |plane, c| {
        var cb: [9 * bps]u8 = undefined;
        const co = bps + 1;
        if (my > 0) {
            @memcpy(cb[1..9], plane[(my * 8 - 1) * uvs + mx * 8 ..][0..8]);
            cb[0] = if (mx > 0) plane[(my * 8 - 1) * uvs + mx * 8 - 1] else 129;
        } else @memset(cb[0..9], 127);
        for (0..8) |y| cb[co + y * bps - 1] = if (mx > 0) plane[(my * 8 + y) * uvs + mx * 8 - 1] else 129;
        predictBig(&cb, co, 8, uvmode, my > 0, mx > 0);
        for (0..4) |k| idct(coeffs[(16 + c * 4 + k) * 16 ..][0..16], cb[co + (k / 2) * 4 * bps + (k % 2) * 4 ..], bps);
        for (0..8) |y| @memcpy(plane[(my * 8 + y) * uvs + mx * 8 ..][0..8], cb[co + y * bps ..][0..8]);
    }
}

// ───────────── петлевой фильтр ─────────────

fn sclip1(v: i32) i32 {
    return std.math.clamp(v, -128, 127);
}
fn sclip2(v: i32) i32 {
    return std.math.clamp(v, -16, 15);
}
fn clip1(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}
fn at(p: []u8, i: usize, k: isize, step: usize) i32 {
    return p[@intCast(@as(isize, @intCast(i)) + k * @as(isize, @intCast(step)))];
}
fn set(p: []u8, i: usize, k: isize, step: usize, v: u8) void {
    p[@intCast(@as(isize, @intCast(i)) + k * @as(isize, @intCast(step)))] = v;
}

fn filter2(p: []u8, i: usize, s: usize) void {
    const p1 = at(p, i, -2, s);
    const p0 = at(p, i, -1, s);
    const q0 = at(p, i, 0, s);
    const q1 = at(p, i, 1, s);
    const a = 3 * (q0 - p0) + sclip1(p1 - q1);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    set(p, i, -1, s, clip1(p0 + a2));
    set(p, i, 0, s, clip1(q0 - a1));
}

fn filter4(p: []u8, i: usize, s: usize) void {
    const p1 = at(p, i, -2, s);
    const p0 = at(p, i, -1, s);
    const q0 = at(p, i, 0, s);
    const q1 = at(p, i, 1, s);
    const a = 3 * (q0 - p0);
    const a1 = sclip2((a + 4) >> 3);
    const a2 = sclip2((a + 3) >> 3);
    const a3 = (a1 + 1) >> 1;
    set(p, i, -2, s, clip1(p1 + a3));
    set(p, i, -1, s, clip1(p0 + a2));
    set(p, i, 0, s, clip1(q0 - a1));
    set(p, i, 1, s, clip1(q1 - a3));
}

fn filter6(p: []u8, i: usize, s: usize) void {
    const p2 = at(p, i, -3, s);
    const p1 = at(p, i, -2, s);
    const p0 = at(p, i, -1, s);
    const q0 = at(p, i, 0, s);
    const q1 = at(p, i, 1, s);
    const q2 = at(p, i, 2, s);
    const a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1));
    const a1 = (27 * a + 63) >> 7;
    const a2 = (18 * a + 63) >> 7;
    const a3 = (9 * a + 63) >> 7;
    set(p, i, -3, s, clip1(p2 + a3));
    set(p, i, -2, s, clip1(p1 + a2));
    set(p, i, -1, s, clip1(p0 + a1));
    set(p, i, 0, s, clip1(q0 - a1));
    set(p, i, 1, s, clip1(q1 - a2));
    set(p, i, 2, s, clip1(q2 - a3));
}

fn hev(p: []u8, i: usize, s: usize, t: i32) bool {
    return @abs(at(p, i, -2, s) - at(p, i, -1, s)) > t or @abs(at(p, i, 1, s) - at(p, i, 0, s)) > t;
}

fn needs(p: []u8, i: usize, s: usize, t: i32) bool {
    return 4 * @as(i32, @intCast(@abs(at(p, i, -1, s) - at(p, i, 0, s)))) + @as(i32, @intCast(@abs(at(p, i, -2, s) - at(p, i, 1, s)))) <= t;
}

fn needs2(p: []u8, i: usize, s: usize, t: i32, it: i32) bool {
    if (!needs(p, i, s, t)) return false;
    const d = [6][2]isize{ .{ -4, -3 }, .{ -3, -2 }, .{ -2, -1 }, .{ 3, 2 }, .{ 2, 1 }, .{ 1, 0 } };
    for (d) |e| if (@abs(at(p, i, e[0], s) - at(p, i, e[1], s)) > it) return false;
    return true;
}

/// Край длиной `n`: `i` — первый пиксель за краем, `s` — шаг поперёк края, `along` — вдоль.
fn loop26(p: []u8, start: usize, s: usize, along: usize, n: usize, t: i32, it: i32, hv: i32) void {
    const t2 = 2 * t + 1;
    for (0..n) |k| {
        const i = start + k * along;
        if (needs2(p, i, s, t2, it)) {
            if (hev(p, i, s, hv)) filter2(p, i, s) else filter6(p, i, s);
        }
    }
}

fn loop24(p: []u8, start: usize, s: usize, along: usize, n: usize, t: i32, it: i32, hv: i32) void {
    const t2 = 2 * t + 1;
    for (0..n) |k| {
        const i = start + k * along;
        if (needs2(p, i, s, t2, it)) {
            if (hev(p, i, s, hv)) filter2(p, i, s) else filter4(p, i, s);
        }
    }
}

fn simple(p: []u8, start: usize, s: usize, along: usize, t: i32) void {
    const t2 = 2 * t + 1;
    for (0..16) |k| {
        const i = start + k * along;
        if (needs(p, i, s, t2)) filter2(p, i, s);
    }
}

fn loopFilter(dec: *Dec, filters: []const Filter, yp: []u8, up: []u8, vp: []u8, ys: usize, uvs: usize) void {
    for (0..dec.mbh) |my| for (0..dec.mbw) |mx| {
        const f = filters[my * dec.mbw + mx];
        if (f.limit == 0) continue;
        const yo = my * 16 * ys + mx * 16;
        const co = my * 8 * uvs + mx * 8;
        if (dec.simple) {
            if (mx > 0) simple(yp, yo, 1, ys, f.limit + 4);
            if (f.inner) for (1..4) |k| simple(yp, yo + 4 * k, 1, ys, f.limit);
            if (my > 0) simple(yp, yo, ys, 1, f.limit + 4);
            if (f.inner) for (1..4) |k| simple(yp, yo + 4 * k * ys, ys, 1, f.limit);
            continue;
        }
        if (mx > 0) {
            loop26(yp, yo, 1, ys, 16, f.limit + 4, f.ilevel, f.hev);
            loop26(up, co, 1, uvs, 8, f.limit + 4, f.ilevel, f.hev);
            loop26(vp, co, 1, uvs, 8, f.limit + 4, f.ilevel, f.hev);
        }
        if (f.inner) {
            for (1..4) |k| loop24(yp, yo + 4 * k, 1, ys, 16, f.limit, f.ilevel, f.hev);
            loop24(up, co + 4, 1, uvs, 8, f.limit, f.ilevel, f.hev);
            loop24(vp, co + 4, 1, uvs, 8, f.limit, f.ilevel, f.hev);
        }
        if (my > 0) {
            loop26(yp, yo, ys, 1, 16, f.limit + 4, f.ilevel, f.hev);
            loop26(up, co, uvs, 1, 8, f.limit + 4, f.ilevel, f.hev);
            loop26(vp, co, uvs, 1, 8, f.limit + 4, f.ilevel, f.hev);
        }
        if (f.inner) {
            for (1..4) |k| loop24(yp, yo + 4 * k * ys, ys, 1, 16, f.limit, f.ilevel, f.hev);
            loop24(up, co + 4 * uvs, uvs, 1, 8, f.limit, f.ilevel, f.hev);
            loop24(vp, co + 4 * uvs, uvs, 1, 8, f.limit, f.ilevel, f.hev);
        }
    };
}
