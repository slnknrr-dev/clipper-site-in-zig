//! JPEG (ITU T.81): разбор baseline и progressive (Хаффман, 8 бит, 1 или 3
//! компоненты, любое прореживание до 4×4, интервалы рестарта) в RGBA8 и запись
//! baseline 4:2:0 со стандартными таблицами (приложение K) нужного качества.
//!
//! Разбор не доверяет входу: размеры проверяются до выделений, предел по
//! пикселям, коды Хаффмана и номера коэффициентов проверены; данные, которых
//! не хватило, читаются нулями — время разбора ограничено числом блоков.

const std = @import("std");
const Image = @import("image.zig").Image;

pub const Error = error{ NotJpeg, Damaged, TooBig, Unsupported, OutOfMemory };

pub fn looksLike(bytes: []const u8) bool {
    return bytes.len > 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF;
}

/// Номер коэффициента в порядке зигзага → номер в блоке 8×8.
pub const zz = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };

// ───────────── Хаффман ─────────────

const Huff = struct {
    vals: [256]u8 = undefined,
    maxcode: [18]i32 = [_]i32{-1} ** 18,
    mincode: [17]i32 = [_]i32{0} ** 17,
    valptr: [17]i32 = [_]i32{0} ** 17,
    defined: bool = false,

    fn build(bits: [16]u8, vals: []const u8) Error!Huff {
        var h = Huff{ .defined = true };
        var total: usize = 0;
        for (bits) |b| total += b;
        if (total > 256 or total != vals.len) return error.Damaged;
        @memcpy(h.vals[0..total], vals);
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |l| {
            const n: i32 = bits[l - 1];
            h.valptr[l] = k;
            h.mincode[l] = code;
            code += n;
            k += n;
            if (code > (@as(i32, 1) << @intCast(l))) return error.Damaged;
            h.maxcode[l] = if (n > 0) code - 1 else -1;
            code <<= 1;
        }
        h.maxcode[17] = std.math.maxInt(i32);
        return h;
    }
};

const Bits = struct {
    d: []const u8,
    pos: usize,
    acc: u32 = 0,
    n: u6 = 0,
    /// встретился маркер: дальше нули
    marker: bool = false,

    fn fill(b: *Bits) void {
        while (b.n <= 24) {
            var byte: u8 = 0;
            if (!b.marker and b.pos < b.d.len) {
                byte = b.d[b.pos];
                if (byte == 0xFF) {
                    const next: u8 = if (b.pos + 1 < b.d.len) b.d[b.pos + 1] else 0xD9;
                    if (next == 0) {
                        b.pos += 2;
                    } else {
                        b.marker = true;
                        byte = 0;
                    }
                } else b.pos += 1;
            }
            b.acc |= @as(u32, byte) << @intCast(24 - @as(u32, b.n));
            b.n += 8;
        }
    }

    fn bits(b: *Bits, n: u5) u32 {
        if (n == 0) return 0;
        if (b.n < n) b.fill();
        const v = b.acc >> @intCast(32 - @as(u32, n));
        b.acc <<= n;
        b.n -= n;
        return v;
    }

    fn bit(b: *Bits) u32 {
        return b.bits(1);
    }

    fn decode(b: *Bits, h: *const Huff) Error!u8 {
        if (!h.defined) return error.Damaged;
        var code: i32 = 0;
        for (1..17) |l| {
            code = (code << 1) | @as(i32, @intCast(b.bit()));
            if (code <= h.maxcode[l]) {
                const i = h.valptr[l] + code - h.mincode[l];
                if (i < 0 or i > 255) return error.Damaged;
                return h.vals[@intCast(i)];
            }
        }
        return error.Damaged;
    }

    /// Рестарт: остаток байта отбрасывается, маркер RSTn пропускается.
    fn restart(b: *Bits) void {
        b.acc = 0;
        b.n = 0;
        b.marker = false;
        while (b.pos + 1 < b.d.len) {
            if (b.d[b.pos] == 0xFF and b.d[b.pos + 1] >= 0xD0 and b.d[b.pos + 1] <= 0xD7) {
                b.pos += 2;
                return;
            }
            if (b.d[b.pos] == 0xFF and b.d[b.pos + 1] != 0 and b.d[b.pos + 1] != 0xFF) return; // чужой маркер
            b.pos += 1;
        }
    }
};

fn extend(v: u32, s: u5) i32 {
    if (s == 0) return 0;
    const vi: i32 = @intCast(v);
    return if (vi < (@as(i32, 1) << (s - 1))) vi - (@as(i32, 1) << s) + 1 else vi;
}

fn sat(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

// ───────────── разбор ─────────────

const Comp = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// блоков по ширине и высоте с дополнением до MCU
    bw: usize = 0,
    bh: usize = 0,
    /// блоков в самой картинке (для одиночных сканов)
    aw: usize = 0,
    ah: usize = 0,
    coef: []i16 = &.{},
    dc_pred: i32 = 0,
    td: u8 = 0,
    ta: u8 = 0,
};

const Dec = struct {
    a: std.mem.Allocator,
    d: []const u8,
    qt: [4][64]u16 = undefined,
    qt_set: [4]bool = .{ false, false, false, false },
    dc: [4]Huff = .{ .{}, .{}, .{}, .{} },
    ac: [4]Huff = .{ .{}, .{}, .{}, .{} },
    comps: [3]Comp = undefined,
    nc: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: usize = 0,
    mcuy: usize = 0,
    progressive: bool = false,
    restart: u32 = 0,
    eobrun: u32 = 0,
    adobe_transform: ?u8 = null,

    fn seg(dec: *Dec, pos: usize) Error![]const u8 {
        if (pos + 2 > dec.d.len) return error.Damaged;
        const len = std.mem.readInt(u16, dec.d[pos..][0..2], .big);
        if (len < 2 or pos + len > dec.d.len) return error.Damaged;
        return dec.d[pos + 2 .. pos + len];
    }

    fn dqt(dec: *Dec, s: []const u8) Error!void {
        var i: usize = 0;
        while (i < s.len) {
            const pq = s[i] >> 4;
            const tq = s[i] & 15;
            if (tq > 3 or pq > 1) return error.Damaged;
            i += 1;
            const n: usize = if (pq == 1) 128 else 64;
            if (i + n > s.len) return error.Damaged;
            for (0..64) |k| dec.qt[tq][zz[k]] = if (pq == 1) std.mem.readInt(u16, s[i + k * 2 ..][0..2], .big) else s[i + k];
            dec.qt_set[tq] = true;
            i += n;
        }
    }

    fn dht(dec: *Dec, s: []const u8) Error!void {
        var i: usize = 0;
        while (i < s.len) {
            if (i + 17 > s.len) return error.Damaged;
            const tc = s[i] >> 4;
            const th = s[i] & 15;
            if (tc > 1 or th > 3) return error.Damaged;
            var bits: [16]u8 = undefined;
            @memcpy(&bits, s[i + 1 .. i + 17]);
            var total: usize = 0;
            for (bits) |b| total += b;
            i += 17;
            if (i + total > s.len) return error.Damaged;
            const h = try Huff.build(bits, s[i .. i + total]);
            if (tc == 0) dec.dc[th] = h else dec.ac[th] = h;
            i += total;
        }
    }

    fn sof(dec: *Dec, s: []const u8, max_pixels: u64) Error!void {
        if (dec.nc != 0) return error.Damaged;
        if (s.len < 6 or s[0] != 8) return error.Unsupported; // только 8 бит
        dec.h = std.mem.readInt(u16, s[1..3], .big);
        dec.w = std.mem.readInt(u16, s[3..5], .big);
        const nc = s[5];
        if (dec.w == 0 or dec.h == 0) return error.Unsupported; // высота из DNL — редкость
        if (nc != 1 and nc != 3) return error.Unsupported; // CMYK не берём
        if (s.len < 6 + @as(usize, nc) * 3) return error.Damaged;
        if (@as(u64, dec.w) * dec.h > max_pixels) return error.TooBig;
        for (0..nc) |k| {
            const c = s[6 + k * 3 ..];
            const hv = c[1];
            const hh = hv >> 4;
            const vv = hv & 15;
            if (hh < 1 or hh > 4 or vv < 1 or vv > 4 or c[2] > 3) return error.Damaged;
            dec.comps[k] = .{ .id = c[0], .h = hh, .v = vv, .tq = c[2] };
            dec.hmax = @max(dec.hmax, hh);
            dec.vmax = @max(dec.vmax, vv);
        }
        dec.nc = nc;
        dec.mcux = (dec.w + 8 * @as(usize, dec.hmax) - 1) / (8 * @as(usize, dec.hmax));
        dec.mcuy = (dec.h + 8 * @as(usize, dec.vmax) - 1) / (8 * @as(usize, dec.vmax));
        var total: u64 = 0;
        for (dec.comps[0..nc]) |*c| {
            c.bw = dec.mcux * c.h;
            c.bh = dec.mcuy * c.v;
            c.aw = ((@as(usize, dec.w) * c.h + dec.hmax - 1) / dec.hmax + 7) / 8;
            c.ah = ((@as(usize, dec.h) * c.v + dec.vmax - 1) / dec.vmax + 7) / 8;
            total += @as(u64, c.bw) * c.bh * 64;
        }
        if (total > 4 * max_pixels + (1 << 20)) return error.TooBig;
        for (dec.comps[0..nc]) |*c| {
            c.coef = try dec.a.alloc(i16, c.bw * c.bh * 64);
            @memset(c.coef, 0);
        }
    }

    fn block(c: *Comp, bx: usize, by: usize) *[64]i16 {
        return c.coef[(by * c.bw + bx) * 64 ..][0..64];
    }

    /// Один блок скана. ss..se, ah, al — параметры progressive (baseline: 0, 63, 0, 0).
    fn decodeBlock(dec: *Dec, br: *Bits, c: *Comp, blk: *[64]i16, ss: u8, se: u8, ah: u8, al: u5) Error!void {
        if (ss == 0) {
            // DC
            if (ah == 0) {
                const t = try br.decode(&dec.dc[c.td]);
                if (t > 11) return error.Damaged;
                const s: u5 = @intCast(t);
                c.dc_pred +%= extend(br.bits(s), s);
                c.dc_pred = std.math.clamp(c.dc_pred, -32768, 32767);
                blk[0] = sat(c.dc_pred << al);
            } else if (br.bit() != 0) blk[0] = sat(@as(i32, blk[0]) | (@as(i32, 1) << al));
            if (!dec.progressive) {
                // baseline: и AC в том же скане
                var k: usize = 1;
                while (k < 64) {
                    const rs = try br.decode(&dec.ac[c.ta]);
                    const r = rs >> 4;
                    const s: u5 = @intCast(rs & 15);
                    if (s == 0) {
                        if (r != 15) break;
                        k += 16;
                        continue;
                    }
                    k += r;
                    if (k > 63) return error.Damaged;
                    blk[zz[k]] = sat(extend(br.bits(s), s));
                    k += 1;
                }
            }
            return;
        }
        if (ah == 0) {
            // AC, первый проход
            if (dec.eobrun > 0) {
                dec.eobrun -= 1;
                return;
            }
            var k: usize = ss;
            while (k <= se) {
                const rs = try br.decode(&dec.ac[c.ta]);
                const r: u5 = @intCast(rs >> 4);
                const s: u5 = @intCast(rs & 15);
                if (s == 0) {
                    if (r < 15) {
                        dec.eobrun = (@as(u32, 1) << r) - 1;
                        if (r > 0) dec.eobrun += br.bits(r);
                        break;
                    }
                    k += 16;
                    continue;
                }
                k += r;
                if (k > se) return error.Damaged;
                blk[zz[k]] = sat(extend(br.bits(s), s) * (@as(i32, 1) << al));
                k += 1;
            }
            return;
        }
        // AC, уточнение
        const p1: i32 = @as(i32, 1) << al;
        const m1: i32 = -p1;
        var k: usize = ss;
        if (dec.eobrun == 0) {
            while (k <= se) : (k += 1) {
                const rs = try br.decode(&dec.ac[c.ta]);
                var r: i32 = rs >> 4;
                const s = rs & 15;
                var val: i32 = 0;
                if (s != 0) {
                    if (s != 1) return error.Damaged;
                    val = if (br.bit() != 0) p1 else m1;
                } else if (r != 15) {
                    dec.eobrun = @as(u32, 1) << @intCast(r);
                    if (r > 0) dec.eobrun += br.bits(@intCast(r));
                    break;
                }
                while (k <= se) {
                    const coef = &blk[zz[k]];
                    if (coef.* != 0) {
                        if (br.bit() != 0 and (coef.* & p1) == 0) coef.* = sat(@as(i32, coef.*) + (if (coef.* >= 0) p1 else m1));
                    } else {
                        r -= 1;
                        if (r < 0) break;
                    }
                    k += 1;
                }
                if (val != 0) {
                    if (k > se) return error.Damaged;
                    blk[zz[k]] = sat(val);
                }
            }
        }
        if (dec.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const coef = &blk[zz[k]];
                if (coef.* != 0 and br.bit() != 0 and (coef.* & p1) == 0) coef.* = sat(@as(i32, coef.*) + (if (coef.* >= 0) p1 else m1));
            }
            dec.eobrun -= 1;
        }
    }

    /// Скан; возвращает позицию после его энтропийных данных.
    fn scan(dec: *Dec, hdr: []const u8, data_at: usize) Error!usize {
        if (dec.nc == 0 or hdr.len < 1) return error.Damaged;
        const ns = hdr[0];
        if (ns < 1 or ns > dec.nc or hdr.len < 1 + @as(usize, ns) * 2 + 3) return error.Damaged;
        var sc: [3]*Comp = undefined;
        for (0..ns) |k| {
            const id = hdr[1 + k * 2];
            const t = hdr[2 + k * 2];
            const c = for (dec.comps[0..dec.nc]) |*c| {
                if (c.id == id) break c;
            } else return error.Damaged;
            c.td = t >> 4;
            c.ta = t & 15;
            if (c.td > 3 or c.ta > 3) return error.Damaged;
            sc[k] = c;
        }
        const p = hdr[1 + @as(usize, ns) * 2 ..];
        const ss = p[0];
        const se = p[1];
        const ah = p[2] >> 4;
        const al = p[2] & 15;
        if (dec.progressive) {
            if (se > 63 or ss > se or al > 13 or ah > 13) return error.Damaged;
            if ((ss == 0) != (se == 0)) return error.Damaged;
            if (ss > 0 and ns != 1) return error.Damaged;
        } else if (ss != 0 or se != 63 or ah != 0 or al != 0) {
            // baseline: допускаем огрехи кодировщиков, кроме смещения
            if (ss != 0) return error.Damaged;
        }
        for (sc[0..ns]) |c| c.dc_pred = 0;
        dec.eobrun = 0;
        var br = Bits{ .d = dec.d, .pos = data_at };
        var todo: u32 = dec.restart;
        if (ns == 1) {
            const c = sc[0];
            for (0..c.ah) |by| for (0..c.aw) |bx| {
                if (dec.restart != 0) {
                    if (todo == 0) {
                        br.restart();
                        c.dc_pred = 0;
                        dec.eobrun = 0;
                        todo = dec.restart;
                    }
                    todo -= 1;
                }
                try dec.decodeBlock(&br, c, block(c, bx, by), ss, se, ah, @intCast(al));
            };
        } else {
            for (0..dec.mcuy) |my| for (0..dec.mcux) |mx| {
                if (dec.restart != 0) {
                    if (todo == 0) {
                        br.restart();
                        for (sc[0..ns]) |c| c.dc_pred = 0;
                        dec.eobrun = 0;
                        todo = dec.restart;
                    }
                    todo -= 1;
                }
                for (sc[0..ns]) |c| for (0..c.v) |v| for (0..c.h) |h| {
                    try dec.decodeBlock(&br, c, block(c, mx * c.h + h, my * c.v + v), ss, se, ah, @intCast(al));
                };
            };
        }
        // конец данных скана: следующий маркер, кроме RSTn
        var i = @min(br.pos, dec.d.len);
        while (i + 1 < dec.d.len) : (i += 1) {
            if (dec.d[i] == 0xFF) {
                const m = dec.d[i + 1];
                if (m != 0 and m != 0xFF and !(m >= 0xD0 and m <= 0xD7)) return i;
            }
        }
        return dec.d.len;
    }
};

// ───────────── ДКП ─────────────

const cos_table = blk: {
    @setEvalBranchQuota(10000);
    var t: [8][8]f32 = undefined;
    for (0..8) |u| for (0..8) |x| {
        const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        t[u][x] = @floatCast(cu * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0) / 2.0);
    };
    break :blk t;
};

fn idct(in: *const [64]f32, out: []u8, stride: usize) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |x| {
        var s: f32 = 0;
        for (0..8) |u| s += cos_table[u][x] * in[y * 8 + u];
        tmp[y * 8 + x] = s;
    };
    for (0..8) |x| for (0..8) |y| {
        var s: f32 = 0;
        for (0..8) |v| s += cos_table[v][y] * tmp[v * 8 + x];
        out[y * stride + x] = @intFromFloat(std.math.clamp(@round(s + 128.0), 0.0, 255.0));
    };
}

fn fdct(in: *const [64]f32, out: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |u| {
        var s: f32 = 0;
        for (0..8) |x| s += cos_table[u][x] * in[y * 8 + x];
        tmp[y * 8 + u] = s;
    };
    for (0..8) |u| for (0..8) |v| {
        var s: f32 = 0;
        for (0..8) |y| s += cos_table[v][y] * tmp[y * 8 + u];
        out[v * 8 + u] = s;
    };
}

/// Ширина и высота без разбора (для уже готовых картинок хранилища).
pub fn size(bytes: []const u8) ?[2]u32 {
    if (!looksLike(bytes)) return null;
    var i: usize = 2;
    while (i + 9 < bytes.len) {
        if (bytes[i] != 0xFF) return null;
        const m = bytes[i + 1];
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (m >= 0xC0 and m <= 0xC2) return .{ std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big), std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big) };
        i += 2 + len;
    }
    return null;
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8, max_pixels: u64) Error!Image {
    if (!looksLike(bytes)) return error.NotJpeg;
    var dec = Dec{ .a = a, .d = bytes };
    defer for (dec.comps[0..dec.nc]) |c| a.free(c.coef);
    var pos: usize = 2;
    var scans: usize = 0;
    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xFF) return error.Damaged;
        const m = bytes[pos + 1];
        if (m == 0xFF) {
            pos += 1; // заполнитель
            continue;
        }
        pos += 2;
        if (m == 0xD9) break; // EOI
        if (m >= 0xD0 and m <= 0xD7) continue;
        const s = try dec.seg(pos);
        const next = pos + 2 + s.len;
        switch (m) {
            0xDB => try dec.dqt(s),
            0xC4 => try dec.dht(s),
            0xC0, 0xC1 => try dec.sof(s, max_pixels),
            0xC2 => {
                dec.progressive = true;
                try dec.sof(s, max_pixels);
            },
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported, // lossless, арифметика
            0xDD => {
                if (s.len < 2) return error.Damaged;
                dec.restart = std.mem.readInt(u16, s[0..2], .big);
            },
            0xDA => {
                scans += 1;
                if (scans > 1000) return error.Damaged;
                pos = try dec.scan(s, next);
                continue;
            },
            0xEE => if (s.len >= 12 and std.mem.startsWith(u8, s, "Adobe")) {
                dec.adobe_transform = s[11];
            },
            else => {}, // APPn, COM и прочее
        }
        pos = next;
    }
    if (dec.nc == 0 or scans == 0) return error.Damaged;
    for (dec.comps[0..dec.nc]) |c| if (!dec.qt_set[c.tq]) return error.Damaged;

    // ДКП и плоскости компонент
    var planes: [3][]u8 = undefined;
    var n_planes: usize = 0;
    defer for (planes[0..n_planes]) |p| a.free(p);
    for (dec.comps[0..dec.nc], 0..) |*c, ci| {
        const pw = c.bw * 8;
        planes[ci] = try a.alloc(u8, pw * c.bh * 8);
        n_planes += 1;
        const q = &dec.qt[c.tq];
        for (0..c.bh) |by| for (0..c.bw) |bx| {
            const blk = Dec.block(c, bx, by);
            var f: [64]f32 = undefined;
            for (0..64) |k| f[k] = @as(f32, @floatFromInt(blk[k])) * @as(f32, @floatFromInt(q[k]));
            idct(&f, planes[ci][(by * 8) * pw + bx * 8 ..], pw);
        };
    }
    const px = try a.alloc(u8, @as(usize, dec.w) * dec.h * 4);
    errdefer a.free(px);
    // RGB без преобразования — только если так сказано (Adobe transform 0 и id 'R','G','B')
    const rgb = dec.nc == 3 and ((dec.adobe_transform != null and dec.adobe_transform.? == 0) or (dec.comps[0].id == 'R' and dec.comps[1].id == 'G' and dec.comps[2].id == 'B'));
    for (0..dec.h) |y| for (0..dec.w) |x| {
        var v: [3]f32 = undefined;
        for (dec.comps[0..dec.nc], 0..) |c, ci| {
            const sx = x * c.h / dec.hmax;
            const sy = y * c.v / dec.vmax;
            v[ci] = @floatFromInt(planes[ci][sy * c.bw * 8 + sx]);
        }
        const o = (y * dec.w + x) * 4;
        if (dec.nc == 1) {
            const g: u8 = @intFromFloat(v[0]);
            px[o..][0..4].* = .{ g, g, g, 255 };
        } else if (rgb) {
            px[o..][0..4].* = .{ @intFromFloat(v[0]), @intFromFloat(v[1]), @intFromFloat(v[2]), 255 };
        } else {
            const yy = v[0];
            const cb = v[1] - 128;
            const cr = v[2] - 128;
            px[o] = clamp8(yy + 1.402 * cr);
            px[o + 1] = clamp8(yy - 0.344136 * cb - 0.714136 * cr);
            px[o + 2] = clamp8(yy + 1.772 * cb);
            px[o + 3] = 255;
        }
    };
    return .{ .w = dec.w, .h = dec.h, .px = px };
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0.0, 255.0));
}

// ───────────── запись ─────────────

const std_lum = [64]u8{ 16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99 };
const std_chr = [_]u8{ 17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99 } ++ [_]u8{99} ** 32;

const dc_lum_bits = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_chr_bits = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const ac_lum_bits = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_lum_vals = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};
const ac_chr_bits = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chr_vals = [162]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};

/// Код Хаффмана каждого символа: длина и биты.
const Codes = struct {
    len: [256]u8 = [_]u8{0} ** 256,
    code: [256]u16 = [_]u16{0} ** 256,

    fn of(bits: [16]u8, vals: []const u8) Codes {
        var c = Codes{};
        var code: u16 = 0;
        var k: usize = 0;
        for (1..17) |l| {
            for (0..bits[l - 1]) |_| {
                c.len[vals[k]] = @intCast(l);
                c.code[vals[k]] = code;
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

const Writer = struct {
    out: *std.ArrayList(u8),
    acc: u32 = 0,
    n: u5 = 0,

    fn put(w: *Writer, bits: u32, len: u5) !void {
        var i: u5 = len;
        while (i > 0) {
            i -= 1;
            w.acc = (w.acc << 1) | ((bits >> i) & 1);
            w.n += 1;
            if (w.n == 8) {
                const b: u8 = @intCast(w.acc & 0xFF);
                try w.out.append(b);
                if (b == 0xFF) try w.out.append(0);
                w.acc = 0;
                w.n = 0;
            }
        }
    }

    fn flush(w: *Writer) !void {
        while (w.n != 0) try w.put(1, 1);
    }
};

fn magnitude(v: i32) struct { u5, u32 } {
    if (v == 0) return .{ 0, 0 };
    const a: u32 = @abs(v);
    const s: u5 = @intCast(32 - @clz(a));
    const bits: u32 = if (v > 0) a else (@as(u32, 1) << s) - 1 - a;
    return .{ s, bits };
}

fn encodeBlock(w: *Writer, f: *const [64]f32, q: *const [64]u16, pred: *i32, dc: *const Codes, ac: *const Codes) !void {
    var c: [64]f32 = undefined;
    fdct(f, &c);
    var z: [64]i32 = undefined;
    for (0..64) |k| {
        const n = zz[k];
        z[k] = std.math.clamp(@as(i32, @intFromFloat(@round(c[n] / @as(f32, @floatFromInt(q[n]))))), -1023, 1023);
    }
    const diff = std.math.clamp(z[0] - pred.*, -2047, 2047);
    pred.* += diff;
    const s, const bits = magnitude(diff);
    try w.put(dc.code[s], @intCast(dc.len[s]));
    try w.put(bits, s);
    var run: u32 = 0;
    for (1..64) |k| {
        if (z[k] == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) {
            try w.put(ac.code[0xF0], @intCast(ac.len[0xF0]));
            run -= 16;
        }
        const as, const ab = magnitude(z[k]);
        const sym: u8 = @intCast((run << 4) | as);
        try w.put(ac.code[sym], @intCast(ac.len[sym]));
        try w.put(ab, as);
        run = 0;
    }
    if (run > 0) try w.put(ac.code[0], @intCast(ac.len[0]));
}

fn quantTable(base: [64]u8, quality: u8) [64]u16 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale: u32 = if (q < 50) 5000 / q else 200 - 2 * q;
    var t: [64]u16 = undefined;
    for (0..64) |k| t[k] = @intCast(std.math.clamp((@as(u32, base[k]) * scale + 50) / 100, 1, 255));
    return t;
}

fn dhtSeg(out: *std.ArrayList(u8), class_id: u8, bits: [16]u8, vals: []const u8) !void {
    try out.appendSlice(&.{ 0xFF, 0xC4 });
    try out.writer().writeInt(u16, @intCast(2 + 1 + 16 + vals.len), .big);
    try out.append(class_id);
    try out.appendSlice(&bits);
    try out.appendSlice(vals);
}

/// Пишет baseline JPEG 4:2:0 (альфа отбрасывается — для непрозрачных картинок).
pub fn encode(a: std.mem.Allocator, img: Image, quality: u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const ql = quantTable(std_lum, quality);
    const qc = quantTable(std_chr, quality);
    try out.appendSlice(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 });
    for ([_]*const [64]u16{ &ql, &qc }, 0..) |t, id| {
        try out.appendSlice(&.{ 0xFF, 0xDB, 0, 67, @intCast(id) });
        for (0..64) |k| try out.append(@intCast(t[zz[k]]));
    }
    try out.appendSlice(&.{ 0xFF, 0xC0, 0, 17, 8 });
    try out.writer().writeInt(u16, @intCast(img.h), .big);
    try out.writer().writeInt(u16, @intCast(img.w), .big);
    try out.appendSlice(&.{ 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1 });
    try dhtSeg(&out, 0x00, dc_lum_bits, &dc_vals);
    try dhtSeg(&out, 0x10, ac_lum_bits, &ac_lum_vals);
    try dhtSeg(&out, 0x01, dc_chr_bits, &dc_vals);
    try dhtSeg(&out, 0x11, ac_chr_bits, &ac_chr_vals);
    try out.appendSlice(&.{ 0xFF, 0xDA, 0, 12, 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 });

    const dcl = Codes.of(dc_lum_bits, &dc_vals);
    const acl = Codes.of(ac_lum_bits, &ac_lum_vals);
    const dcc = Codes.of(dc_chr_bits, &dc_vals);
    const acc = Codes.of(ac_chr_bits, &ac_chr_vals);
    var w = Writer{ .out = &out };
    var pred = [3]i32{ 0, 0, 0 };
    const mw = (img.w + 15) / 16;
    const mh = (img.h + 15) / 16;
    for (0..mh) |my| for (0..mw) |mx| {
        // яркость — четыре блока, цветность — усреднение 2×2 в один
        var ycc: [3][16][16]f32 = undefined;
        for (0..16) |dy| for (0..16) |dx| {
            const x = @min(mx * 16 + dx, img.w - 1);
            const y = @min(my * 16 + dy, img.h - 1);
            const p = img.px[(y * img.w + x) * 4 ..][0..3];
            const r: f32 = @floatFromInt(p[0]);
            const g: f32 = @floatFromInt(p[1]);
            const b: f32 = @floatFromInt(p[2]);
            ycc[0][dy][dx] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
            ycc[1][dy][dx] = -0.168736 * r - 0.331264 * g + 0.5 * b;
            ycc[2][dy][dx] = 0.5 * r - 0.418688 * g - 0.081312 * b;
        };
        for (0..2) |by| for (0..2) |bx| {
            var f: [64]f32 = undefined;
            for (0..8) |y| for (0..8) |x| {
                f[y * 8 + x] = ycc[0][by * 8 + y][bx * 8 + x];
            };
            try encodeBlock(&w, &f, &ql, &pred[0], &dcl, &acl);
        };
        for (1..3) |ci| {
            var f: [64]f32 = undefined;
            for (0..8) |y| for (0..8) |x| {
                f[y * 8 + x] = (ycc[ci][y * 2][x * 2] + ycc[ci][y * 2 + 1][x * 2] + ycc[ci][y * 2][x * 2 + 1] + ycc[ci][y * 2 + 1][x * 2 + 1]) / 4;
            };
            try encodeBlock(&w, &f, &qc, &pred[ci], &dcc, &acc);
        }
    };
    try w.flush();
    try out.appendSlice(&.{ 0xFF, 0xD9 });
    return out.toOwnedSlice();
}

test "jpeg: запись и разбор туда и обратно близки к исходнику" {
    const a = std.testing.allocator;
    const W = 37;
    const H = 23;
    var px: [W * H * 4]u8 = undefined;
    for (0..H) |y| for (0..W) |x| {
        px[(y * W + x) * 4 ..][0..4].* = .{ @intCast(x * 6), @intCast(y * 10), @intCast((x + y) * 3), 255 };
    };
    const f = try encode(a, .{ .w = W, .h = H, .px = &px }, 90);
    defer a.free(f);
    try std.testing.expectEqual([2]u32{ W, H }, size(f).?);
    const back = try decode(a, f, 1 << 20);
    defer a.free(back.px);
    try std.testing.expectEqual(@as(u32, W), back.w);
    var err: u64 = 0;
    for (px, back.px) |p, q| err += @abs(@as(i32, p) - q);
    // средняя ошибка на канал — меньше 4 из 255
    try std.testing.expect(err / px.len < 4);
}

test "jpeg: враждебный ввод" {
    const a = std.testing.allocator;
    var px: [32 * 32 * 4]u8 = undefined;
    for (&px, 0..) |*b, k| b.* = @intCast((k * 37) % 256);
    const f = try encode(a, .{ .w = 32, .h = 32, .px = &px }, 75);
    defer a.free(f);
    try std.testing.expectError(error.TooBig, decode(a, f, 100));
    for (0..f.len) |n| if (decode(a, f[0..n], 1 << 20)) |im| a.free(im.px) else |_| {};
    const bad = try a.dupe(u8, f);
    defer a.free(bad);
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    for (0..3000) |_| {
        @memcpy(bad, f);
        for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| bad[rnd.uintLessThan(usize, bad.len)] = rnd.int(u8);
        if (decode(a, bad, 1 << 20)) |im| a.free(im.px) else |_| {}
    }
}
