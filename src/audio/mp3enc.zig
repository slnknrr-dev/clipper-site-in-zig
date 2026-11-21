//! Запись MP3 «как до 2003 года» (BACKLOG_RU.md §22): MPEG-1 Layer III, постоянный
//! битрейт 128 кбит/с, 32/44,1/48 кГц, моно или joint stereo (M/S по кадру),
//! только длинные блоки, без служебного кадра Xing/LAME и без ID3v2 — такой файл
//! играет любой проигрыватель того времени.
//!
//! Путь: многофазный банк анализа (то же окно, что у синтеза, /32) → МДКП 36
//! точек → обратное снятие наложения → квантование: общий шаг global_gain на
//! гранулу подбирается делением пополам под бюджет битов; множители масштаба
//! нулевые. Тише порога слышимости шаг не мельчится — в паузах (аудиокниги!)
//! биты копятся в запасе (bit reservoir, до 511 байт) и тратятся на громкое.
//! Коды Хаффмана — таблицы стандарта (mp3tab.zig), выбор таблицы по области.

const std = @import("std");
const tab = @import("mp3tab.zig");
const dec = @import("mp3dec.zig");

pub const bitrate = 128;

/// Частоты, которые пишет кодер (MPEG-1).
pub fn rateOk(r: u32) bool {
    return r == 32000 or r == 44100 or r == 48000;
}

const max_frame = 144 * bitrate * 1000 / 32000 + 1;

const Frame = struct {
    b: [max_frame]u8 = undefined,
    len: usize = 0,
    /// Начало области основных данных (после заголовка и побочной информации).
    slot: usize = 0,
};

const GrCh = struct {
    part23: u32 = 0,
    big_values: u32 = 0,
    gg: u32 = 210,
    table: [3]u8 = .{ 0, 0, 0 },
    region0: u32 = 0,
    region1: u32 = 0,
    count1t: u1 = 0,
};

pub const Encoder = struct {
    rate: u32,
    ch: u8,
    sri: u2,
    out: std.io.AnyWriter,
    // банк анализа: последние 512 отсчётов, новые — в начале (кольцо)
    x: [2][512]f32 = std.mem.zeroes([2][512]f32),
    xoff: [2]usize = .{ 0, 0 },
    prev: [2][32][18]f32 = std.mem.zeroes([2][32][18]f32),
    inbuf: [2][1152]f32 = undefined,
    inlen: usize = 0,
    // очередь кадров, ещё не заполненных основными данными
    q: [8]Frame = undefined,
    qn: usize = 0,
    /// Курсор основных данных: кадр очереди и позиция в нём.
    cf: usize = 0,
    cp: usize = 0,
    reservoir: usize = 0,
    pad_acc: u32 = 0,
    lowpass: usize,
    frames: u64 = 0,
    bytes: u64 = 0,

    pub fn init(out: std.io.AnyWriter, rate: u32, channels: u8) Encoder {
        std.debug.assert(rateOk(rate) and (channels == 1 or channels == 2));
        const sri: u2 = switch (rate) {
            44100 => 0,
            48000 => 1,
            else => 2,
        };
        // срез частот: стерео 16 кГц, моно 18 кГц (128 кбит/с на всё не хватает)
        const cut: f32 = if (channels == 2) 16000 else 18000;
        const lp: usize = @intFromFloat(@min(576.0, cut / (@as(f32, @floatFromInt(rate)) / 2.0) * 576.0));
        return .{ .rate = rate, .ch = channels, .sri = sri, .out = out, .lowpass = lp };
    }

    /// Отсчёты по каналам (для моно `r` не читается).
    pub fn push(e: *Encoder, l: []const f32, r: []const f32) !void {
        var i: usize = 0;
        while (i < l.len) {
            const n = @min(1152 - e.inlen, l.len - i);
            @memcpy(e.inbuf[0][e.inlen..][0..n], l[i..][0..n]);
            if (e.ch == 2) @memcpy(e.inbuf[1][e.inlen..][0..n], r[i..][0..n]);
            e.inlen += n;
            i += n;
            if (e.inlen == 1152) {
                try e.frame();
                e.inlen = 0;
            }
        }
    }

    /// Дописать хвост (тишиной до целого кадра и ещё кадр на задержку банков).
    pub fn finish(e: *Encoder) !void {
        if (e.inlen > 0) {
            for (0..e.ch) |c| @memset(e.inbuf[c][e.inlen..], 0);
            try e.frame();
        }
        for (0..e.ch) |c| @memset(&e.inbuf[c], 0);
        e.inlen = 0;
        try e.frame();
        // всё, что в очереди, — как есть (пустые байты — нули)
        for (e.q[0..e.qn]) |*f| try e.emit(f);
        e.qn = 0;
    }

    fn emit(e: *Encoder, f: *const Frame) !void {
        try e.out.writeAll(f.b[0..f.len]);
        e.bytes += f.len;
    }

    fn frame(e: *Encoder) !void {
        // размер кадра и набивка
        const num: u32 = 144 * bitrate * 1000;
        var size: usize = num / e.rate;
        e.pad_acc += num % e.rate;
        var pad = false;
        if (e.pad_acc >= e.rate) {
            e.pad_acc -= e.rate;
            pad = true;
            size += 1;
        }
        const side_len: usize = if (e.ch == 1) 17 else 32;
        const slot = size - 4 - side_len;

        // спектр двух гранул
        var xr: [2][2][576]f32 = undefined;
        for (0..2) |gi| {
            var sub: [2][18][32]f32 = undefined;
            for (0..18) |t| for (0..e.ch) |c| e.analysis(c, e.inbuf[c][gi * 576 + t * 32 ..][0..32], &sub[c][t]);
            for (0..e.ch) |c| e.mdct(c, &sub[c], &xr[gi][c]);
        }
        // M/S, если стороны почти нет
        var ms = false;
        if (e.ch == 2) {
            var em: f64 = 0;
            var es: f64 = 0;
            for (0..2) |gi| for (0..576) |i| {
                const m = xr[gi][0][i] + xr[gi][1][i];
                const s = xr[gi][0][i] - xr[gi][1][i];
                em += m * m;
                es += s * s;
            };
            ms = es < 0.4 * em;
            if (ms) {
                const k = 1.0 / @sqrt(2.0);
                for (0..2) |gi| for (0..576) |i| {
                    const m = (xr[gi][0][i] + xr[gi][1][i]) * k;
                    const s = (xr[gi][0][i] - xr[gi][1][i]) * k;
                    xr[gi][0][i] = m;
                    xr[gi][1][i] = s;
                };
            }
        }
        for (0..2) |gi| for (0..e.ch) |c| for (e.lowpass..576) |i| {
            xr[gi][c][i] = 0;
        };

        // бюджет: свой слот плюс половина запаса
        const main_begin = e.reservoir;
        sri_cur = e.sri;
        var budget: usize = (slot + e.reservoir / 2) * 8;
        var bw = BitBuf{};
        var gc: [2][2]GrCh = undefined;
        var ix: [2][576]u16 = undefined;
        for (0..2) |gi| {
            const share = if (gi == 0) budget / 2 else budget;
            const used = quantize(&xr[gi], e.ch, share, &ix, &gc[gi]);
            budget -= @min(budget, used);
            for (0..e.ch) |c| {
                const start = bw.n;
                writeGranule(&bw, &ix[c], &xr[gi][c], &gc[gi][c]);
                // последняя гранула кадра добивается единицами до границы байта:
                // декодеры хранят остаток кадра побайтно (единицы — нулевые четвёрки)
                if (gi == 1 and c + 1 == e.ch) while (bw.n & 7 != 0 and bw.n - start < 4095) bw.put(1, 1);
                gc[gi][c].part23 = @intCast(bw.n - start);
            }
        }
        const main_bytes = (bw.n + 7) / 8;
        std.debug.assert(main_bytes <= slot + e.reservoir);

        // новый кадр: заголовок и побочная информация
        if (e.qn == e.q.len) {
            try e.emit(&e.q[0]);
            std.mem.copyForwards(Frame, e.q[0 .. e.qn - 1], e.q[1..e.qn]);
            e.qn -= 1;
            if (e.cf > 0) e.cf -= 1;
        }
        const f = &e.q[e.qn];
        f.* = .{};
        f.len = size;
        @memset(f.b[0..size], 0);
        // стерео — всегда joint stereo, M/S включается флагом: смену режима между
        // кадрами ffmpeg (а с ним Chrome) принимает за разрыв и глушит гранулу
        const mode: u8 = if (e.ch == 1) 3 else 1;
        f.b[0] = 0xFF;
        f.b[1] = 0xFB; // MPEG-1, Layer III, без CRC
        f.b[2] = (9 << 4) | (@as(u8, e.sri) << 2) | (@as(u8, @intFromBool(pad)) << 1);
        f.b[3] = (mode << 6) | (@as(u8, if (ms) 2 else 0) << 4) | 0x04; // «оригинал»
        var sb = BitBuf{};
        sb.put(@intCast(main_begin), 9);
        sb.put(0, if (e.ch == 1) 5 else 3);
        for (0..e.ch) |_| sb.put(0, 4); // scfsi
        for (0..2) |gi| for (0..e.ch) |c| {
            const g = gc[gi][c];
            sb.put(g.part23, 12);
            sb.put(g.big_values, 9);
            sb.put(g.gg, 8);
            sb.put(0, 4); // scalefac_compress
            sb.put(0, 1); // без переключения окон
            for (g.table) |t| sb.put(t, 5);
            sb.put(g.region0, 4);
            sb.put(g.region1, 3);
            sb.put(0, 1); // preflag
            sb.put(0, 1); // scalefac_scale
            sb.put(g.count1t, 1);
        };
        @memcpy(f.b[4 .. 4 + side_len], sb.b[0..side_len]);
        f.slot = 4 + side_len;
        e.qn += 1;
        if (e.qn == 1) {
            e.cf = 0;
            e.cp = f.slot;
        }

        // основные данные — с курсора (в хвосты прошлых кадров, потом в свой слот)
        var k: usize = 0;
        while (k < main_bytes) : (k += 1) {
            while (e.cp >= e.q[e.cf].len) {
                e.cf += 1;
                e.cp = e.q[e.cf].slot;
            }
            e.q[e.cf].b[e.cp] = bw.b[k];
            e.cp += 1;
        }
        // запас: свободное от курсора до конца очереди; больше 511 — пропуск (нули)
        e.reservoir = e.free();
        while (e.reservoir > 511) {
            const skip = e.reservoir - 511;
            const room = e.q[e.cf].len - e.cp;
            if (room == 0) {
                e.cf += 1;
                e.cp = e.q[e.cf].slot;
                continue;
            }
            e.cp += @min(skip, room);
            e.reservoir = e.free();
        }
        // готовые кадры (до кадра курсора) — в файл
        while (e.cf > 0) {
            try e.emit(&e.q[0]);
            std.mem.copyForwards(Frame, e.q[0 .. e.qn - 1], e.q[1..e.qn]);
            e.qn -= 1;
            e.cf -= 1;
        }
        e.frames += 1;
    }

    fn free(e: *const Encoder) usize {
        var n: usize = e.q[e.cf].len - e.cp;
        for (e.q[e.cf + 1 .. e.qn]) |f| n += f.len - f.slot;
        return n;
    }

    /// 32 новых отсчёта (по времени) → 32 полосы.
    fn analysis(e: *Encoder, c: usize, s: *const [32]f32, out: *[32]f32) void {
        const x = &e.x[c];
        // кольцо: x[(off + i) % 512] = X[i], X[0] — самый новый
        const off = (e.xoff[c] + 512 - 32) % 512;
        for (0..32) |i| x[(off + 31 - i) % 512] = s[i];
        e.xoff[c] = off;
        const w = getWin();
        var y: [64]f32 = undefined;
        for (0..64) |i| {
            var acc: f32 = 0;
            for (0..8) |j| acc += w[i + 64 * j] * x[(off + i + 64 * j) % 512];
            y[i] = acc;
        }
        const m = getMat();
        for (0..32) |i| {
            var acc: f32 = 0;
            for (0..64) |k| acc += m[i][k] * y[k];
            out[i] = acc;
        }
    }

    fn mdct(e: *Encoder, c: usize, sub: *const [18][32]f32, xr: *[576]f32) void {
        const cm = getMdct();
        for (0..32) |sb| {
            var z: [36]f32 = undefined;
            for (0..18) |t| {
                var v = sub[t][sb];
                if (sb & 1 == 1 and t & 1 == 1) v = -v;
                z[t] = e.prev[c][sb][t];
                z[18 + t] = v;
                e.prev[c][sb][t] = v;
            }
            for (0..18) |k| {
                var acc: f32 = 0;
                for (0..36) |i| acc += z[i] * cm[k][i];
                xr[sb * 18 + k] = acc;
            }
        }
        // обратное снятию наложения у декодера (транспонированная бабочка)
        for (1..32) |sb| for (0..8) |i| {
            const a = xr[sb * 18 - 1 - i];
            const b = xr[sb * 18 + i];
            xr[sb * 18 - 1 - i] = a * cs_ca[0][i] + b * cs_ca[1][i];
            xr[sb * 18 + i] = b * cs_ca[0][i] - a * cs_ca[1][i];
        };
    }
};

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

var an_win: [512]f32 = undefined;
var an_mat: [32][64]f32 = undefined;
var md_mat: [18][36]f32 = undefined;
var ready = false;

fn initTabs() void {
    if (ready) return;
    const d = dec.window();
    for (0..512) |i| an_win[i] = d[i] / 32.0;
    for (0..32) |i| for (0..64) |k| {
        const a = std.math.pi / 64.0 * @as(f64, @floatFromInt(2 * i + 1)) * (@as(f64, @floatFromInt(k)) - 16.0);
        an_mat[i][k] = @floatCast(@cos(a));
    };
    for (0..18) |k| for (0..36) |i| {
        const fi: f64 = @floatFromInt(i);
        const w = @sin(std.math.pi / 36.0 * (fi + 0.5));
        const a = std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 19) * (2 * k + 1)));
        md_mat[k][i] = @floatCast(w * @cos(a) / 9.0);
    };
    ready = true;
}
fn getWin() *const [512]f32 {
    initTabs();
    return &an_win;
}
fn getMat() *const [32][64]f32 {
    initTabs();
    return &an_mat;
}
fn getMdct() *const [18][36]f32 {
    initTabs();
    return &md_mat;
}

// ───────────── квантование и подсчёт битов ─────────────

const max_ix = 8191 + 15;
/// Не мельче этого шага: ниже примерно -90 дБ от полной шкалы — тишина.
const gg_floor = 150;

/// Квантует гранулу общим шагом под бюджет `budget` битов (на все каналы).
/// Возвращает потраченные биты.
fn quantize(xr: *const [2][576]f32, nch: u8, budget: usize, ix: *[2][576]u16, gc: *[2]GrCh) usize {
    var x34: [2][576]f32 = undefined;
    var peak: f32 = 0;
    for (0..nch) |c| for (0..576) |i| {
        const a = @abs(xr[c][i]);
        x34[c][i] = std.math.pow(f32, a, 0.75);
        peak = @max(peak, x34[c][i]);
    };
    // наименьший шаг, при котором значения влезают в 13 доп. битов
    var lo: i32 = gg_floor;
    while (lo < 255 and peak * stepInv(lo) + 0.4054 > max_ix) lo += 1;
    var hi: i32 = 255;
    // меньший gg — точнее и дороже; ищем наименьший, что влезает
    if (bitsAt(&x34, nch, lo, ix, gc) <= budget) {
        return bitsAt(&x34, nch, lo, ix, gc);
    }
    while (hi - lo > 1) {
        const mid = @divTrunc(lo + hi, 2);
        if (bitsAt(&x34, nch, mid, ix, gc) <= budget) hi = mid else lo = mid;
    }
    return bitsAt(&x34, nch, hi, ix, gc);
}

fn stepInv(gg: i32) f32 {
    return std.math.exp2(-0.1875 * @as(f32, @floatFromInt(gg - 210)));
}

fn bitsAt(x34: *const [2][576]f32, nch: u8, gg: i32, ix: *[2][576]u16, gc: *[2]GrCh) usize {
    const k = stepInv(gg);
    var total: usize = 0;
    for (0..nch) |c| {
        for (0..576) |i| {
            const v = x34[c][i] * k + 0.4054;
            ix[c][i] = @intFromFloat(@min(v, max_ix));
        }
        gc[c] = .{ .gg = @intCast(gg) };
        var bits = plan(&ix[c], &gc[c], sri_cur);
        if (bits > 4095) bits = 1 << 20; // часть 2_3 не больше 4095
        total += bits;
    }
    return total;
}

/// Частота текущего кадра для таблиц полос (кодер однопоточный).
var sri_cur: u2 = 0;

const subdv = [23][2]u8{
    .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 1 },
    .{ 1, 2 }, .{ 2, 2 }, .{ 2, 3 }, .{ 2, 3 }, .{ 3, 4 }, .{ 3, 4 }, .{ 3, 4 }, .{ 4, 5 },
    .{ 4, 5 }, .{ 4, 6 }, .{ 5, 6 }, .{ 5, 6 }, .{ 5, 7 }, .{ 6, 7 }, .{ 6, 7 },
};

/// Раскладка гранулы на области и таблицы; возвращает число битов.
fn plan(ix: *const [576]u16, g: *GrCh, sri: u2) usize {
    var rz: usize = 576;
    while (rz > 1 and ix[rz - 1] == 0 and ix[rz - 2] == 0) rz -= 2;
    var bv = rz;
    while (bv >= 4 and ix[bv - 1] <= 1 and ix[bv - 2] <= 1 and ix[bv - 3] <= 1 and ix[bv - 4] <= 1) bv -= 4;
    // четвёрки: [bv, rz); rz - bv кратно 4
    var bits: usize = 0;
    // таблица четвёрок
    var ca: usize = 0;
    var cb: usize = 0;
    var i = bv;
    while (i + 4 <= rz) : (i += 4) {
        const q: usize = @as(usize, ix[i]) * 8 + @as(usize, ix[i + 1]) * 4 + @as(usize, ix[i + 2]) * 2 + ix[i + 3];
        const s: usize = @as(usize, ix[i]) + ix[i + 1] + ix[i + 2] + ix[i + 3];
        ca += tab.quad[0].lens[q] + s;
        cb += 4 + s;
    }
    g.count1t = if (cb < ca) 1 else 0;
    bits += @min(ca, cb);
    g.big_values = @intCast(bv / 2);
    if (bv == 0) {
        g.table = .{ 0, 0, 0 };
        g.region0 = 0;
        g.region1 = 0;
        return bits;
    }
    // полоса, в которой кончаются большие значения
    const w = dec.longWidths(@as(u4, sri));
    var ends: [23]usize = undefined;
    var acc: usize = 0;
    for (0..22) |b| {
        acc += w[b];
        ends[b] = acc;
    }
    ends[22] = 576;
    var band: usize = 0;
    while (band < 21 and ends[band] < bv) band += 1;
    var r0: usize = subdv[band][0];
    var r1: usize = subdv[band][1];
    // области не длиннее больших значений
    while (r0 > 0 and ends[r0] > bv) r0 -= 1;
    while (r1 > 0 and ends[r0 + r1 + 1] > bv) r1 -= 1;
    g.region0 = @intCast(r0);
    g.region1 = @intCast(r1);
    const b1 = @min(ends[r0], bv);
    const b2 = @min(ends[r0 + r1 + 1], bv);
    const bounds = [4]usize{ 0, b1, b2, bv };
    for (0..3) |r| {
        const t = chooseTable(ix[bounds[r]..bounds[r + 1]]);
        g.table[r] = t.table;
        bits += t.bits;
    }
    return bits;
}

const Choice = struct { table: u8, bits: usize };

fn chooseTable(v: []const u16) Choice {
    if (v.len == 0) return .{ .table = 0, .bits = 0 };
    var m: u16 = 0;
    for (v) |x| m = @max(m, x);
    if (m == 0) return .{ .table = 0, .bits = 0 };
    if (m <= 15) {
        const groups = [_][]const u8{ &.{1}, &.{ 2, 3 }, &.{ 5, 6 }, &.{ 7, 8, 9 }, &.{ 10, 11, 12 }, &.{ 13, 15 } };
        const maxv = [_]u16{ 1, 2, 3, 5, 7, 15 };
        for (groups, maxv) |grp, mv| {
            if (m > mv) continue;
            var best = Choice{ .table = grp[0], .bits = std.math.maxInt(usize) };
            for (grp) |t| {
                const b = countBits(v, t);
                if (b < best.bits) best = .{ .table = t, .bits = b };
            }
            return best;
        }
        unreachable;
    }
    const need = m - 15;
    var best = Choice{ .table = 0, .bits = std.math.maxInt(usize) };
    for ([_]u8{ 16, 24 }) |base| {
        var t = base;
        while (t < base + 8 and (@as(u32, 1) << @intCast(tab.linbits[t])) <= need) t += 1;
        if (t >= base + 8) continue;
        const b = countBits(v, t);
        if (b < best.bits) best = .{ .table = t, .bits = b };
    }
    return best;
}

fn countBits(v: []const u16, t: u8) usize {
    const h = tab.big[t].?;
    const lb: usize = tab.linbits[t];
    var bits: usize = 0;
    var i: usize = 0;
    while (i + 1 < v.len) : (i += 2) {
        var x: usize = v[i];
        var y: usize = v[i + 1];
        if (x >= 15 and lb > 0) {
            x = 15;
            bits += lb;
        }
        if (y >= 15 and lb > 0) {
            y = 15;
            bits += lb;
        }
        bits += h.lens[x * h.xlen + y] + @intFromBool(x != 0) + @intFromBool(y != 0);
    }
    return bits;
}

fn writeGranule(bw: *BitBuf, ix: *const [576]u16, xr: *const [576]f32, g: *const GrCh) void {
    const bv = g.big_values * 2;
    // те же границы, что в plan
    const w = dec.longWidths(@as(u4, sri_cur));
    var ends: [23]usize = undefined;
    var acc: usize = 0;
    for (0..22) |b| {
        acc += w[b];
        ends[b] = acc;
    }
    ends[22] = 576;
    const b1 = @min(ends[g.region0], bv);
    const b2 = @min(ends[g.region0 + g.region1 + 1], bv);
    var i: usize = 0;
    while (i < bv) : (i += 2) {
        const t = g.table[if (i < b1) @as(usize, 0) else if (i < b2) @as(usize, 1) else 2];
        if (t == 0) continue;
        const h = tab.big[t].?;
        const lb: u5 = @intCast(tab.linbits[t]);
        const x0 = ix[i];
        const y0 = ix[i + 1];
        const x: usize = if (lb > 0 and x0 >= 15) 15 else x0;
        const y: usize = if (lb > 0 and y0 >= 15) 15 else y0;
        const s = x * h.xlen + y;
        bw.put(h.codes[s], @intCast(h.lens[s]));
        if (x == 15 and lb > 0) bw.put(x0 - 15, lb);
        if (x0 != 0) bw.put(@intFromBool(xr[i] < 0), 1);
        if (y == 15 and lb > 0) bw.put(y0 - 15, lb);
        if (y0 != 0) bw.put(@intFromBool(xr[i + 1] < 0), 1);
    }
    // четвёрки до последнего ненулевого
    var rz: usize = 576;
    while (rz > 1 and ix[rz - 1] == 0 and ix[rz - 2] == 0) rz -= 2;
    i = bv;
    while (i + 4 <= rz) : (i += 4) {
        const q: usize = @as(usize, ix[i]) * 8 + @as(usize, ix[i + 1]) * 4 + @as(usize, ix[i + 2]) * 2 + ix[i + 3];
        const h = tab.quad[g.count1t];
        bw.put(h.codes[q], @intCast(h.lens[q]));
        for (0..4) |j| if (ix[i + j] != 0) bw.put(@intFromBool(xr[i + j] < 0), 1);
    }
}

const BitBuf = struct {
    b: [8192]u8 = .{0} ** 8192,
    n: usize = 0,

    fn put(w: *BitBuf, v: u32, len: u5) void {
        var k = len;
        while (k > 0) {
            k -= 1;
            const bit: u8 = @intCast((v >> k) & 1);
            w.b[w.n >> 3] |= bit << @intCast(7 - (w.n & 7));
            w.n += 1;
        }
    }
};
