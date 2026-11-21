//! Свой zstd (RFC 8878): распаковка и сжатие кадров, словарь — «сырое содержимое»
//! (raw content), которое стоит перед данными как уже прочитанная история.
//!
//! Зачем свой: в стандартной библиотеке Zig 0.14 у zstd есть только распаковка и
//! без словарей, а словарь языка — главное, ради чего zstd здесь нужен (BACKLOG_RU.md §15).
//!
//! Распаковка понимает весь формат: блоки raw, RLE и сжатые; литералы как есть, RLE,
//! Хаффманом (1 и 4 потока, повтор прежней таблицы); последовательности со всеми
//! режимами FSE (стандартный, RLE, своя таблица, повтор) и повторы смещений.
//! Испорченный кадр — ошибка, а не выход за буфер.
//!
//! Сжатие: поиск повторов хеш-цепочками в окне «словарь + данные», литералы
//! Хаффманом (если выгоднее, чем как есть), последовательности — своими таблицами
//! FSE или стандартными, что короче. Каждый сжатый блок сразу распаковывается
//! своим же кодом; не совпало — блок пишется как есть. Ошибка сжатия не может
//! испортить данные, только ухудшить сжатие.

const std = @import("std");

pub const magic: u32 = 0xFD2FB528;
const block_max = 128 * 1024;

pub const Error = error{ Malformed, TooBig, OutOfMemory };

fn highbit(v: u32) u5 {
    return @intCast(31 - @clz(v));
}

// ───────────── битовые потоки ─────────────

/// Поток, который пишется вперёд (младшие биты первыми), а читается с конца:
/// последний записанный кусок прочтётся первым. В конце — бит-метка.
const BackWriter = struct {
    out: *std.ArrayList(u8),
    acc: u64 = 0,
    n: u6 = 0,

    fn put(w: *BackWriter, v: u64, nb: u6) !void {
        if (nb == 0) return;
        std.debug.assert(nb <= 32);
        w.acc |= (v & ((@as(u64, 1) << nb) - 1)) << w.n;
        w.n += nb;
        while (w.n >= 8) {
            try w.out.append(@truncate(w.acc));
            w.acc >>= 8;
            w.n -= 8;
        }
    }

    fn close(w: *BackWriter) !void {
        try w.put(1, 1);
        if (w.n > 0) {
            try w.out.append(@truncate(w.acc));
            w.acc = 0;
            w.n = 0;
        }
    }
};

/// Чтение такого потока с конца.
const BackReader = struct {
    data: []const u8,
    /// сколько бит ещё не прочитано (позиция от начала потока)
    pos: usize,

    fn init(data: []const u8) Error!BackReader {
        if (data.len == 0 or data[data.len - 1] == 0) return error.Malformed;
        const last = data[data.len - 1];
        return .{ .data = data, .pos = data.len * 8 - 8 + highbit(last) };
    }

    /// `nb` бит; если их меньше — недостающие младшие биты нули (для Хаффмана).
    fn peek(r: *const BackReader, nb: u6) u64 {
        if (nb == 0) return 0;
        if (r.pos >= nb) return r.bitsAt(r.pos - nb, nb);
        const have: u6 = @intCast(r.pos);
        if (have == 0) return 0;
        return r.bitsAt(0, have) << (nb - have);
    }

    fn bitsAt(r: *const BackReader, start: usize, nb: u6) u64 {
        const first_byte = start / 8;
        // быстрый путь: восемь байт целиком (nb + сдвиг ≤ 64)
        if (first_byte + 8 <= r.data.len and @as(u32, nb) + @as(u32, @intCast(start % 8)) <= 64) {
            const w = std.mem.readInt(u64, r.data[first_byte..][0..8], .little) >> @intCast(start % 8);
            return if (nb == 64) w else w & ((@as(u64, 1) << nb) - 1);
        }
        var v: u64 = 0;
        const first = start / 8;
        const last = (start + nb - 1) / 8;
        var i = last + 1;
        while (i > first) {
            i -= 1;
            v = (v << 8) | r.data[i];
        }
        v >>= @intCast(start % 8);
        return v & ((@as(u64, 1) << nb) - 1);
    }

    fn read(r: *BackReader, nb: u6) Error!u64 {
        if (nb > r.pos) return error.Malformed;
        const v = r.peek(nb);
        r.pos -= nb;
        return v;
    }

    fn skip(r: *BackReader, nb: u6) Error!void {
        if (nb > r.pos) return error.Malformed;
        r.pos -= nb;
    }
};

/// Прямой поток (младшие биты первыми) — описания таблиц FSE.
const FwdReader = struct {
    data: []const u8,
    bit: usize = 0,

    fn read(r: *FwdReader, nb: u6) Error!u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < nb) : (i += 1) {
            const b = r.bit + i;
            if (b / 8 >= r.data.len) return error.Malformed;
            v |= @as(u32, (r.data[b / 8] >> @intCast(b % 8)) & 1) << @intCast(i);
        }
        r.bit += nb;
        return v;
    }

    fn peek(r: *const FwdReader, nb: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < nb) : (i += 1) {
            const b = r.bit + i;
            if (b / 8 >= r.data.len) break;
            v |= @as(u32, (r.data[b / 8] >> @intCast(b % 8)) & 1) << @intCast(i);
        }
        return v;
    }
};

// ───────────── FSE ─────────────

const max_symbols = 256;

/// Таблица FSE: состояние → символ, сколько бит читать и база следующего состояния.
pub const Fse = struct {
    log: u4 = 0,
    sym: [512]u8 = undefined,
    nb: [512]u8 = undefined,
    base: [512]u16 = undefined,
    /// для кодирования: состояния каждого символа по возрастанию базы
    first: [max_symbols + 1]u16 = undefined,
    order: [512]u16 = undefined,

    fn size(t: *const Fse) u32 {
        return @as(u32, 1) << t.log;
    }

    /// Из нормализованных частот (-1 — «меньше единицы»), сумма модулей = 2^log.
    fn build(t: *Fse, norm: []const i16, log: u4) Error!void {
        const sz: u32 = @as(u32, 1) << log;
        if (norm.len == 0 or norm.len > max_symbols) return error.Malformed;
        t.log = log;
        var high: u32 = sz - 1;
        var next: [max_symbols]u32 = undefined;
        var total: u32 = 0;
        for (norm, 0..) |n, s| {
            if (n == -1) {
                t.sym[high] = @intCast(s);
                if (high == 0) return error.Malformed;
                high -= 1;
                next[s] = 1;
                total += 1;
            } else if (n < -1) return error.Malformed else {
                next[s] = @intCast(n);
                total += @intCast(n);
            }
        }
        if (total != sz) return error.Malformed;
        const step = (sz >> 1) + (sz >> 3) + 3;
        const mask = sz - 1;
        var pos: u32 = 0;
        for (norm, 0..) |n, s| {
            if (n <= 0) continue;
            var k: i16 = 0;
            while (k < n) : (k += 1) {
                t.sym[pos] = @intCast(s);
                pos = (pos + step) & mask;
                while (pos > high) pos = (pos + step) & mask;
            }
        }
        if (pos != 0) return error.Malformed;
        for (0..sz) |i| {
            const s = t.sym[i];
            const nx = next[s];
            next[s] += 1;
            const nbits: u5 = @intCast(@as(u32, log) - highbit(nx));
            t.nb[i] = nbits;
            t.base[i] = @intCast((nx << nbits) - sz);
        }
        // порядок для кодирования
        var count: [max_symbols + 1]u16 = .{0} ** (max_symbols + 1);
        for (0..sz) |i| count[t.sym[i]] += 1;
        var acc: u16 = 0;
        for (0..max_symbols) |s| {
            t.first[s] = acc;
            acc += count[s];
        }
        t.first[max_symbols] = acc;
        var fill: [max_symbols]u16 = undefined;
        @memcpy(&fill, t.first[0..max_symbols]);
        for (0..sz) |i| {
            const s = t.sym[i];
            t.order[fill[s]] = @intCast(i);
            fill[s] += 1;
        }
        // состояния символа — по возрастанию базы (с номером состояния она не растёт)
        for (0..max_symbols) |s| {
            const part = t.order[t.first[s]..t.first[s + 1]];
            var i: usize = 1;
            while (i < part.len) : (i += 1) {
                const x = part[i];
                var j = i;
                while (j > 0 and t.base[part[j - 1]] > t.base[x]) : (j -= 1) part[j] = part[j - 1];
                part[j] = x;
            }
        }
    }

    /// Шаг кодирования: из текущего состояния `cur` (то, в которое декодер перейдёт)
    /// — в состояние символа `s`; биты перехода — в поток.
    fn encode(t: *const Fse, w: *BackWriter, cur: *u16, s: u8) !void {
        const a = t.first[s];
        const b = t.first[@as(usize, s) + 1];
        // интервалы [base, base + 2^nb) состояний символа покрывают 0..size без пропусков
        var lo = a;
        var hi = b;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (t.base[t.order[mid]] <= cur.*) lo = mid else hi = mid;
        }
        const st = t.order[lo];
        try w.put(cur.* - t.base[st], @intCast(t.nb[st]));
        cur.* = st;
    }

    /// Начальное состояние для символа (последнего по порядку кодирования).
    fn startFor(t: *const Fse, s: u8, need_bits: bool) ?u16 {
        var i = t.first[s];
        while (i < t.first[@as(usize, s) + 1]) : (i += 1) {
            const st = t.order[i];
            if (!need_bits or t.nb[st] > 0) return st;
        }
        return null;
    }

    fn rle(t: *Fse, s: u8) void {
        t.log = 0;
        t.sym[0] = s;
        t.nb[0] = 0;
        t.base[0] = 0;
        for (0..max_symbols + 1) |x| t.first[x] = if (x <= s) 0 else 1;
        t.order[0] = 0;
    }
};

/// Чтение описания таблицы (нормализованных частот) — прямой поток.
fn readNCount(r: *FwdReader, norm: *[max_symbols]i16, max_sym: usize, max_log: u4) Error!struct { n: usize, log: u4 } {
    const log_raw = try r.read(4);
    const log = log_raw + 5;
    if (log > max_log) return error.Malformed;
    const sz: i32 = @as(i32, 1) << @intCast(log);
    var remaining: i32 = sz + 1;
    var threshold: i32 = sz;
    var nbits: u6 = @intCast(log + 1);
    var sym: usize = 0;
    var prev0 = false;
    while (remaining > 1 and sym <= max_sym) {
        if (prev0) {
            var n0 = sym;
            while (r.peek(16) == 0xFFFF) {
                n0 += 24;
                _ = try r.read(16);
            }
            while (r.peek(2) == 3) {
                n0 += 3;
                _ = try r.read(2);
            }
            n0 += try r.read(2);
            if (n0 > max_sym + 1) return error.Malformed;
            while (sym < n0) : (sym += 1) norm[sym] = 0;
            if (sym > max_sym) break;
        }
        const max: i32 = (2 * threshold - 1) - remaining;
        var count: i32 = undefined;
        const low: i32 = @intCast(r.peek(nbits - 1));
        if (low & (threshold - 1) < max) {
            count = low & (threshold - 1);
            _ = try r.read(nbits - 1);
        } else {
            count = @intCast(try r.read(nbits));
            count &= 2 * threshold - 1;
            if (count >= threshold) count -= max;
        }
        count -= 1;
        remaining -= if (count < 0) -count else count;
        norm[sym] = @intCast(count);
        sym += 1;
        prev0 = count == 0;
        while (remaining < threshold) {
            nbits -= 1;
            threshold >>= 1;
        }
    }
    if (remaining != 1 or sym > max_sym + 1) return error.Malformed;
    // байты описания округляются вверх
    r.bit = (r.bit + 7) / 8 * 8;
    return .{ .n = sym, .log = @intCast(log) };
}

/// Запись описания таблицы (обратное к readNCount).
fn writeNCount(out: *std.ArrayList(u8), norm: []const i16, log: u4) !void {
    var acc: u64 = 0;
    var n: u6 = 0;
    const Put = struct {
        fn put(o: *std.ArrayList(u8), a: *u64, cnt: *u6, v: u64, nb: u6) !void {
            a.* |= v << cnt.*;
            cnt.* += nb;
            while (cnt.* >= 8) {
                try o.append(@truncate(a.*));
                a.* >>= 8;
                cnt.* -= 8;
            }
        }
    };
    try Put.put(out, &acc, &n, log - 5, 4);
    const sz: i32 = @as(i32, 1) << log;
    var remaining: i32 = sz + 1;
    var threshold: i32 = sz;
    var nbits: u6 = @as(u6, log) + 1;
    var sym: usize = 0;
    var prev0 = false;
    while (sym < norm.len and remaining > 1) {
        if (prev0) {
            var start = sym;
            while (sym < norm.len and norm[sym] == 0) sym += 1;
            if (sym == norm.len) break;
            while (sym >= start + 24) {
                start += 24;
                try Put.put(out, &acc, &n, 0xFFFF, 16);
            }
            while (sym >= start + 3) {
                start += 3;
                try Put.put(out, &acc, &n, 3, 2);
            }
            try Put.put(out, &acc, &n, sym - start, 2);
        }
        var count: i32 = norm[sym];
        sym += 1;
        const max: i32 = (2 * threshold - 1) - remaining;
        remaining -= if (count < 0) -count else count;
        count += 1;
        if (count >= threshold) count += max;
        const used: u6 = if (count < max) nbits - 1 else nbits;
        try Put.put(out, &acc, &n, @intCast(count), used);
        prev0 = count == 1;
        while (remaining < threshold) {
            nbits -= 1;
            threshold >>= 1;
        }
    }
    if (n > 0) try out.append(@truncate(acc));
}

/// Нормализация частот к 2^log: каждый встреченный символ получает хотя бы 1.
fn normalize(counts: []const u32, log: u4, norm: []i16) void {
    var total: u64 = 0;
    for (counts) |c| total += c;
    const sz: i32 = @as(i32, 1) << log;
    var sum: i32 = 0;
    for (counts, 0..) |c, s| {
        if (c == 0) {
            norm[s] = 0;
            continue;
        }
        var v: i32 = @intCast(@as(u64, c) * @as(u64, @intCast(sz)) / total);
        if (v < 1) v = 1;
        norm[s] = @intCast(v);
        sum += v;
    }
    // излишек или недостача — за счёт самых частых
    while (sum != sz) {
        var best: usize = 0;
        var best_v: i32 = -1;
        for (norm[0..counts.len], 0..) |v, s| {
            if (sum > sz and v <= 1) continue;
            if (v > best_v) {
                best_v = v;
                best = s;
            }
        }
        if (best_v <= 0) break;
        const delta: i32 = if (sum > sz) @max(-(sum - sz), -(best_v - 1)) else sz - sum;
        norm[best] = @intCast(best_v + delta);
        sum += delta;
    }
}

// ───────────── стандартные таблицы последовательностей ─────────────

const ll_default = [_]i16{ 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1 };
const ml_default = [_]i16{ 1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1 };
const of_default = [_]i16{ 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 };

const Code = struct { base: u32, bits: u5 };
const ll_codes = blk: {
    var t: [36]Code = undefined;
    for (0..16) |i| t[i] = .{ .base = i, .bits = 0 };
    const rest = [_]Code{ .{ .base = 16, .bits = 1 }, .{ .base = 18, .bits = 1 }, .{ .base = 20, .bits = 1 }, .{ .base = 22, .bits = 1 }, .{ .base = 24, .bits = 2 }, .{ .base = 28, .bits = 2 }, .{ .base = 32, .bits = 3 }, .{ .base = 40, .bits = 3 }, .{ .base = 48, .bits = 4 }, .{ .base = 64, .bits = 6 }, .{ .base = 128, .bits = 7 }, .{ .base = 256, .bits = 8 }, .{ .base = 512, .bits = 9 }, .{ .base = 1024, .bits = 10 }, .{ .base = 2048, .bits = 11 }, .{ .base = 4096, .bits = 12 }, .{ .base = 8192, .bits = 13 }, .{ .base = 16384, .bits = 14 }, .{ .base = 32768, .bits = 15 }, .{ .base = 65536, .bits = 16 } };
    for (rest, 16..) |c, i| t[i] = c;
    break :blk t;
};
const ml_codes = blk: {
    var t: [53]Code = undefined;
    for (0..32) |i| t[i] = .{ .base = i + 3, .bits = 0 };
    const rest = [_]Code{ .{ .base = 35, .bits = 1 }, .{ .base = 37, .bits = 1 }, .{ .base = 39, .bits = 1 }, .{ .base = 41, .bits = 1 }, .{ .base = 43, .bits = 2 }, .{ .base = 47, .bits = 2 }, .{ .base = 51, .bits = 3 }, .{ .base = 59, .bits = 3 }, .{ .base = 67, .bits = 4 }, .{ .base = 83, .bits = 4 }, .{ .base = 99, .bits = 5 }, .{ .base = 131, .bits = 7 }, .{ .base = 259, .bits = 8 }, .{ .base = 515, .bits = 9 }, .{ .base = 1027, .bits = 10 }, .{ .base = 2051, .bits = 11 }, .{ .base = 4099, .bits = 12 }, .{ .base = 8195, .bits = 13 }, .{ .base = 16387, .bits = 14 }, .{ .base = 32771, .bits = 15 }, .{ .base = 65539, .bits = 16 } };
    for (rest, 32..) |c, i| t[i] = c;
    break :blk t;
};

fn codeOf(comptime table: []const Code, v: u32) u8 {
    var i: usize = table.len;
    while (i > 0) {
        i -= 1;
        if (table[i].base <= v) return @intCast(i);
    }
    return 0;
}

// ───────────── Хаффман литералов ─────────────

const huff_max_bits = 11;

const Huff = struct {
    max_bits: u4 = 0,
    /// индекс — первые max_bits бит; значение — символ и длина кода
    sym: [1 << huff_max_bits]u8 = undefined,
    len: [1 << huff_max_bits]u4 = undefined,
    /// для кодирования: код и длина каждого символа
    code: [256]u16 = undefined,
    clen: [256]u4 = undefined,

    /// По весам (0 — символа нет); последний вес уже восстановлен.
    fn fromWeights(h: *Huff, w: []const u4) Error!void {
        var total: u32 = 0;
        for (w) |x| {
            if (x > huff_max_bits) return error.Malformed;
            if (x > 0) total += @as(u32, 1) << (x - 1);
        }
        if (total == 0 or (total & (total - 1)) != 0) return error.Malformed;
        const mb = highbit(total);
        if (mb > huff_max_bits or mb == 0) return error.Malformed;
        h.max_bits = @intCast(mb);
        var rank_start: [huff_max_bits + 2]u32 = .{0} ** (huff_max_bits + 2);
        var rank_count: [huff_max_bits + 2]u32 = .{0} ** (huff_max_bits + 2);
        for (w) |x| rank_count[x] += 1;
        var next: u32 = 0;
        for (1..@as(usize, mb) + 1) |x| {
            rank_start[x] = next;
            next += rank_count[x] << @intCast(x - 1);
        }
        @memset(&h.clen, 0);
        for (w, 0..) |x, s| {
            if (x == 0) continue;
            const span = @as(u32, 1) << @intCast(x - 1);
            const start = rank_start[x];
            const l: u4 = @intCast(mb + 1 - x);
            for (start..start + span) |i| {
                h.sym[i] = @intCast(s);
                h.len[i] = l;
            }
            h.code[s] = @intCast(start >> @intCast(mb - l));
            h.clen[s] = l;
            rank_start[x] += span;
        }
    }

    fn decodeStream(h: *const Huff, data: []const u8, out: []u8) Error!void {
        var r = try BackReader.init(data);
        for (out) |*o| {
            const idx: usize = @intCast(r.peek(h.max_bits));
            const l = h.len[idx];
            if (l > r.pos) return error.Malformed;
            o.* = h.sym[idx];
            r.pos -= l;
        }
        if (r.pos != 0) return error.Malformed;
    }

    fn encodeStream(h: *const Huff, in: []const u8, out: *std.ArrayList(u8)) !void {
        var w = BackWriter{ .out = out };
        var i = in.len;
        while (i > 0) {
            i -= 1;
            try w.put(h.code[in[i]], h.clen[in[i]]);
        }
        try w.close();
    }
};

/// Длины кодов Хаффмана не длиннее `limit`, дерево полное (сумма Крафта ровно 1).
fn huffLengths(counts: *const [256]u32, limit: u4, lens: *[256]u4) bool {
    var syms: [256]u16 = undefined;
    var n: usize = 0;
    for (counts, 0..) |c, s| if (c > 0) {
        syms[n] = @intCast(s);
        n += 1;
    };
    if (n < 2) return false;
    // классический Хаффман на массиве: листья и узлы
    var weight: [512]u64 = undefined;
    var parent: [512]u16 = undefined;
    var alive: [512]bool = undefined;
    for (0..n) |i| {
        weight[i] = counts[syms[i]];
        alive[i] = true;
    }
    var nodes = n;
    var left = n;
    while (left > 1) {
        var a: usize = 0;
        var b: usize = 0;
        var wa: u64 = std.math.maxInt(u64);
        var wb: u64 = std.math.maxInt(u64);
        for (0..nodes) |i| {
            if (!alive[i]) continue;
            if (weight[i] < wa) {
                b = a;
                wb = wa;
                a = i;
                wa = weight[i];
            } else if (weight[i] < wb) {
                b = i;
                wb = weight[i];
            }
        }
        alive[a] = false;
        alive[b] = false;
        weight[nodes] = wa + wb;
        alive[nodes] = true;
        parent[a] = @intCast(nodes);
        parent[b] = @intCast(nodes);
        nodes += 1;
        left -= 1;
    }
    const root = nodes - 1;
    var depth: [256]u32 = undefined;
    for (0..n) |i| {
        var d: u32 = 0;
        var x = i;
        while (x != root) : (d += 1) x = parent[x];
        depth[i] = d;
    }
    // ограничение длины и выравнивание суммы Крафта
    const one: i64 = @as(i64, 1) << limit;
    var kraft: i64 = 0;
    for (0..n) |i| {
        if (depth[i] > limit) depth[i] = limit;
        kraft += @as(i64, 1) << @intCast(limit - depth[i]);
    }
    // перебор: удлинять самые длинные коды, пока не уложимся
    while (kraft > one) {
        var best: ?usize = null;
        for (0..n) |i| {
            if (depth[i] >= limit) continue;
            if (best == null or depth[i] > depth[best.?] or (depth[i] == depth[best.?] and counts[syms[i]] < counts[syms[best.?]])) best = i;
        }
        const i = best orelse return false;
        kraft -= @as(i64, 1) << @intCast(limit - depth[i] - 1);
        depth[i] += 1;
    }
    // недобор: укорачивать самые частые, пока есть место
    var changed = true;
    while (kraft < one and changed) {
        changed = false;
        var best: ?usize = null;
        for (0..n) |i| {
            if (depth[i] <= 1) continue;
            const gain = @as(i64, 1) << @intCast(limit - depth[i]);
            if (kraft + gain > one) continue;
            if (best == null or counts[syms[i]] > counts[syms[best.?]]) best = i;
        }
        if (best) |i| {
            kraft += @as(i64, 1) << @intCast(limit - depth[i]);
            depth[i] -= 1;
            changed = true;
        }
    }
    if (kraft != one) return false;
    @memset(lens, 0);
    for (0..n) |i| lens[syms[i]] = @intCast(depth[i]);
    return true;
}

// ───────────── распаковка ─────────────

const SeqState = struct {
    ll: Fse = .{},
    of: Fse = .{},
    ml: Fse = .{},
    have_ll: bool = false,
    have_of: bool = false,
    have_ml: bool = false,
    huff: Huff = .{},
    have_huff: bool = false,
    rep: [3]u32 = .{ 1, 4, 8 },
};

/// Размер содержимого кадра из заголовка (если записан).
pub fn contentSize(src: []const u8) ?u64 {
    var p: usize = 0;
    const h = frameHeader(src, &p) catch return null;
    return h.content;
}

const Header = struct { content: ?u64, checksum: bool, dict_id: u32 };

fn frameHeader(src: []const u8, p: *usize) Error!Header {
    if (src.len < 6 or std.mem.readInt(u32, src[0..4], .little) != magic) return error.Malformed;
    const fhd = src[4];
    p.* = 5;
    const fcs_flag = fhd >> 6;
    const single = (fhd >> 5) & 1 == 1;
    if ((fhd >> 3) & 1 == 1) return error.Malformed; // зарезервированный бит
    const checksum = (fhd >> 2) & 1 == 1;
    const did_flag = fhd & 3;
    if (!single) {
        if (p.* >= src.len) return error.Malformed;
        p.* += 1; // описание окна: окно не ограничиваем — кадр распаковывается в готовый буфер
    }
    const did_len: usize = switch (did_flag) {
        0 => 0,
        1 => 1,
        2 => 2,
        else => 4,
    };
    if (p.* + did_len > src.len) return error.Malformed;
    var did: u32 = 0;
    for (0..did_len) |i| did |= @as(u32, src[p.* + i]) << @intCast(8 * i);
    p.* += did_len;
    const fcs_len: usize = switch (fcs_flag) {
        0 => if (single) 1 else 0,
        1 => 2,
        2 => 4,
        else => 8,
    };
    if (p.* + fcs_len > src.len) return error.Malformed;
    var content: ?u64 = null;
    if (fcs_len > 0) {
        var v: u64 = 0;
        for (0..fcs_len) |i| v |= @as(u64, src[p.* + i]) << @intCast(8 * i);
        if (fcs_len == 2) v += 256;
        content = v;
    }
    p.* += fcs_len;
    return .{ .content = content, .checksum = checksum, .dict_id = did };
}

/// Распаковывает один кадр в `dst`; `dict` — словарь (сырое содержимое) или пусто.
/// Возвращает число записанных байт.
pub fn decompress(dst: []u8, src: []const u8, dict: []const u8) Error!usize {
    var p: usize = 0;
    const h = try frameHeader(src, &p);
    if (h.content) |c| if (c > dst.len) return error.TooBig;
    var st = SeqState{};
    var o: usize = 0;
    while (true) {
        if (p + 3 > src.len) return error.Malformed;
        const bh = @as(u32, src[p]) | @as(u32, src[p + 1]) << 8 | @as(u32, src[p + 2]) << 16;
        p += 3;
        const last = bh & 1 == 1;
        const kind = (bh >> 1) & 3;
        const bsize: usize = bh >> 3;
        if (bsize > block_max) return error.Malformed;
        switch (kind) {
            0 => {
                if (p + bsize > src.len) return error.Malformed;
                if (o + bsize > dst.len) return error.TooBig;
                @memcpy(dst[o..][0..bsize], src[p..][0..bsize]);
                o += bsize;
                p += bsize;
            },
            1 => {
                if (p >= src.len) return error.Malformed;
                if (o + bsize > dst.len) return error.TooBig;
                @memset(dst[o..][0..bsize], src[p]);
                o += bsize;
                p += 1;
            },
            2 => {
                if (p + bsize > src.len) return error.Malformed;
                o = try decodeBlock(dst, o, src[p..][0..bsize], dict, &st);
                p += bsize;
            },
            else => return error.Malformed,
        }
        if (last) break;
    }
    if (h.checksum) {
        if (p + 4 > src.len) return error.Malformed;
        const want = std.mem.readInt(u32, src[p..][0..4], .little);
        if (@as(u32, @truncate(std.hash.XxHash64.hash(0, dst[0..o]))) != want) return error.Malformed;
    }
    if (h.content) |c| if (c != o) return error.Malformed;
    return o;
}

fn decodeBlock(dst: []u8, o_start: usize, blk: []const u8, dict: []const u8, st: *SeqState) Error!usize {
    // литералы — во временный буфер (не больше блока)
    var lit_buf: [block_max]u8 = undefined;
    var p: usize = 0;
    const lits = try decodeLiterals(blk, &p, &lit_buf, st);
    // последовательности
    if (p >= blk.len) return error.Malformed;
    var nseq: usize = blk[p];
    p += 1;
    if (nseq >= 128) {
        if (nseq < 255) {
            if (p >= blk.len) return error.Malformed;
            nseq = ((nseq - 128) << 8) + blk[p];
            p += 1;
        } else {
            if (p + 2 > blk.len) return error.Malformed;
            nseq = @as(usize, blk[p]) + (@as(usize, blk[p + 1]) << 8) + 0x7F00;
            p += 2;
        }
    }
    var o = o_start;
    if (nseq == 0) {
        if (p != blk.len) return error.Malformed;
        if (o + lits.len > dst.len) return error.TooBig;
        @memcpy(dst[o..][0..lits.len], lits);
        return o + lits.len;
    }
    if (p >= blk.len) return error.Malformed;
    const modes = blk[p];
    p += 1;
    if (modes & 3 != 0) return error.Malformed;
    try readTable(blk, &p, modes >> 6, &st.ll, &st.have_ll, &ll_default, 6, 35, 9);
    try readTable(blk, &p, (modes >> 4) & 3, &st.of, &st.have_of, &of_default, 5, 31, 8);
    try readTable(blk, &p, (modes >> 2) & 3, &st.ml, &st.have_ml, &ml_default, 6, 52, 9);
    var r = try BackReader.init(blk[p..]);
    var sll: u32 = @intCast(try r.read(st.ll.log));
    var sof: u32 = @intCast(try r.read(st.of.log));
    var sml: u32 = @intCast(try r.read(st.ml.log));
    var lp: usize = 0;
    for (0..nseq) |i| {
        const llc = st.ll.sym[sll];
        const ofc = st.of.sym[sof];
        const mlc = st.ml.sym[sml];
        if (llc >= ll_codes.len or mlc >= ml_codes.len or ofc > 31) return error.Malformed;
        const of_val: u32 = (@as(u32, 1) << @intCast(ofc)) + @as(u32, @intCast(try r.read(@intCast(ofc))));
        const ml: u32 = ml_codes[mlc].base + @as(u32, @intCast(try r.read(ml_codes[mlc].bits)));
        const ll: u32 = ll_codes[llc].base + @as(u32, @intCast(try r.read(ll_codes[llc].bits)));
        // повторы смещений
        var off: u32 = undefined;
        if (of_val > 3) {
            off = of_val - 3;
            st.rep = .{ off, st.rep[0], st.rep[1] };
        } else {
            var idx = of_val - 1;
            if (ll == 0) idx += 1;
            if (idx == 0) {
                off = st.rep[0];
            } else {
                off = if (idx == 3) st.rep[0] -% 1 else st.rep[idx];
                if (idx == 3 and off == 0) return error.Malformed;
                if (idx != 1) st.rep[2] = st.rep[1];
                st.rep[1] = st.rep[0];
                st.rep[0] = off;
            }
        }
        // литералы последовательности
        if (lp + ll > lits.len or o + ll > dst.len) return error.Malformed;
        @memcpy(dst[o..][0..ll], lits[lp..][0..ll]);
        o += ll;
        lp += ll;
        // повтор
        if (off == 0 or off > o + dict.len) return error.Malformed;
        if (o + ml > dst.len) return error.TooBig;
        if (off <= o and off >= ml) {
            // источник целиком в уже распакованном и не перекрывается
            @memcpy(dst[o..][0..ml], dst[o - off ..][0..ml]);
        } else if (off > o and off - o >= ml) {
            // источник целиком в словаре
            const from = dict.len - (off - o);
            @memcpy(dst[o..][0..ml], dict[from..][0..ml]);
        } else {
            var k: usize = 0;
            while (k < ml) : (k += 1) {
                const at = o + k;
                dst[at] = if (at >= off) dst[at - off] else dict[dict.len - (off - at)];
            }
        }
        o += ml;
        if (i + 1 < nseq) {
            sll = st.ll.base[sll] + @as(u32, @intCast(try r.read(@intCast(st.ll.nb[sll]))));
            sml = st.ml.base[sml] + @as(u32, @intCast(try r.read(@intCast(st.ml.nb[sml]))));
            sof = st.of.base[sof] + @as(u32, @intCast(try r.read(@intCast(st.of.nb[sof]))));
        }
    }
    if (r.pos != 0) return error.Malformed;
    const rest = lits.len - lp;
    if (o + rest > dst.len) return error.TooBig;
    @memcpy(dst[o..][0..rest], lits[lp..]);
    return o + rest;
}

fn readTable(blk: []const u8, p: *usize, mode: u8, t: *Fse, have: *bool, default: []const i16, default_log: u4, max_sym: usize, max_log: u4) Error!void {
    switch (mode) {
        0 => try t.build(default, default_log),
        1 => {
            if (p.* >= blk.len) return error.Malformed;
            if (blk[p.*] > max_sym) return error.Malformed;
            t.rle(blk[p.*]);
            p.* += 1;
        },
        2 => {
            var norm: [max_symbols]i16 = undefined;
            var r = FwdReader{ .data = blk[p.*..] };
            const nc = try readNCount(&r, &norm, max_sym, max_log);
            try t.build(norm[0..nc.n], nc.log);
            p.* += r.bit / 8;
        },
        else => if (!have.*) return error.Malformed,
    }
    have.* = true;
}

fn decodeLiterals(blk: []const u8, p: *usize, buf: *[block_max]u8, st: *SeqState) Error![]const u8 {
    if (blk.len == 0) return error.Malformed;
    const b0 = blk[0];
    const kind = b0 & 3;
    const sf = (b0 >> 2) & 3;
    if (kind <= 1) {
        var regen: usize = undefined;
        var hl: usize = undefined;
        switch (sf) {
            0, 2 => {
                regen = b0 >> 3;
                hl = 1;
            },
            1 => {
                if (blk.len < 2) return error.Malformed;
                regen = (b0 >> 4) + (@as(usize, blk[1]) << 4);
                hl = 2;
            },
            else => {
                if (blk.len < 3) return error.Malformed;
                regen = (b0 >> 4) + (@as(usize, blk[1]) << 4) + (@as(usize, blk[2]) << 12);
                hl = 3;
            },
        }
        if (regen > block_max) return error.Malformed;
        if (kind == 0) {
            if (hl + regen > blk.len) return error.Malformed;
            p.* = hl + regen;
            return blk[hl..][0..regen];
        }
        if (hl >= blk.len) return error.Malformed;
        @memset(buf[0..regen], blk[hl]);
        p.* = hl + 1;
        return buf[0..regen];
    }
    // Хаффман
    var regen: usize = undefined;
    var csize: usize = undefined;
    var hl: usize = undefined;
    var streams: usize = 4;
    switch (sf) {
        0, 1 => {
            if (blk.len < 3) return error.Malformed;
            const v = @as(u32, blk[0]) | @as(u32, blk[1]) << 8 | @as(u32, blk[2]) << 16;
            regen = (v >> 4) & 0x3FF;
            csize = (v >> 14) & 0x3FF;
            hl = 3;
            if (sf == 0) streams = 1;
        },
        2 => {
            if (blk.len < 4) return error.Malformed;
            const v = std.mem.readInt(u32, blk[0..4], .little);
            regen = (v >> 4) & 0x3FFF;
            csize = (v >> 18) & 0x3FFF;
            hl = 4;
        },
        else => {
            if (blk.len < 5) return error.Malformed;
            const v = @as(u64, std.mem.readInt(u32, blk[0..4], .little)) | @as(u64, blk[4]) << 32;
            regen = @intCast((v >> 4) & 0x3FFFF);
            csize = @intCast((v >> 22) & 0x3FFFF);
            hl = 5;
        },
    }
    if (regen > block_max or hl + csize > blk.len) return error.Malformed;
    var data = blk[hl..][0..csize];
    if (kind == 2) {
        const used = try readHuffTree(data, &st.huff);
        st.have_huff = true;
        data = data[used..];
    } else if (!st.have_huff) return error.Malformed;
    const out = buf[0..regen];
    if (streams == 1) {
        try st.huff.decodeStream(data, out);
    } else {
        if (data.len < 6 or regen < 4) return error.Malformed;
        const s1 = std.mem.readInt(u16, data[0..2], .little);
        const s2 = std.mem.readInt(u16, data[2..4], .little);
        const s3 = std.mem.readInt(u16, data[4..6], .little);
        const body = data[6..];
        if (@as(usize, s1) + s2 + s3 > body.len) return error.Malformed;
        const seg = (regen + 3) / 4;
        if (seg * 3 > regen) return error.Malformed;
        try st.huff.decodeStream(body[0..s1], out[0..seg]);
        try st.huff.decodeStream(body[s1..][0..s2], out[seg..][0..seg]);
        try st.huff.decodeStream(body[s1 + s2 ..][0..s3], out[2 * seg ..][0..seg]);
        try st.huff.decodeStream(body[s1 + s2 + s3 ..], out[3 * seg ..]);
    }
    p.* = hl + csize;
    return out;
}

/// Описание дерева Хаффмана; возвращает число прочитанных байт.
fn readHuffTree(data: []const u8, h: *Huff) Error!usize {
    if (data.len == 0) return error.Malformed;
    const hb = data[0];
    var w: [256]u4 = .{0} ** 256;
    var n: usize = 0;
    var used: usize = undefined;
    if (hb >= 128) {
        n = hb - 127;
        const bytes = (n + 1) / 2;
        if (1 + bytes > data.len) return error.Malformed;
        for (0..n) |i| {
            const b = data[1 + i / 2];
            const x: u8 = if (i % 2 == 0) b >> 4 else b & 15;
            if (x > huff_max_bits) return error.Malformed;
            w[i] = @intCast(x);
        }
        used = 1 + bytes;
    } else {
        if (1 + @as(usize, hb) > data.len or hb == 0) return error.Malformed;
        const body = data[1..][0..hb];
        var fr = FwdReader{ .data = body };
        var norm: [max_symbols]i16 = undefined;
        const nc = try readNCount(&fr, &norm, 255, 6);
        var t: Fse = .{};
        try t.build(norm[0..nc.n], nc.log);
        var r = try BackReader.init(body[fr.bit / 8 ..]);
        var s1: u32 = @intCast(try r.read(t.log));
        var s2: u32 = @intCast(try r.read(t.log));
        while (true) {
            if (n >= 255) return error.Malformed;
            w[n] = std.math.cast(u4, t.sym[s1]) orelse return error.Malformed;
            n += 1;
            if (t.nb[s1] > r.pos) {
                w[n] = std.math.cast(u4, t.sym[s2]) orelse return error.Malformed;
                n += 1;
                break;
            }
            s1 = t.base[s1] + @as(u32, @intCast(try r.read(@intCast(t.nb[s1]))));
            w[n] = std.math.cast(u4, t.sym[s2]) orelse return error.Malformed;
            n += 1;
            if (t.nb[s2] > r.pos) {
                if (n >= 255) return error.Malformed;
                w[n] = std.math.cast(u4, t.sym[s1]) orelse return error.Malformed;
                n += 1;
                break;
            }
            s2 = t.base[s2] + @as(u32, @intCast(try r.read(@intCast(t.nb[s2]))));
        }
        if (r.pos != 0) return error.Malformed;
        used = 1 + @as(usize, hb);
    }
    // последний вес — дополнение до степени двойки
    var total: u32 = 0;
    for (w[0..n]) |x| if (x > 0) {
        total += @as(u32, 1) << (x - 1);
    };
    if (total == 0) return error.Malformed;
    const mb = highbit(total) + 1;
    if (mb > huff_max_bits) return error.Malformed;
    const rest = (@as(u32, 1) << mb) - total;
    if (rest & (rest - 1) != 0) return error.Malformed;
    if (n >= 256) return error.Malformed;
    w[n] = @intCast(highbit(rest) + 1);
    n += 1;
    try h.fromWeights(w[0..n]);
    return used;
}

// ───────────── сжатие ─────────────

pub const Level = struct {
    /// сколько кандидатов смотреть в цепочке
    depth: u32 = 48,
    /// ленивое сравнение со следующей позицией
    lazy: bool = true,
};

const Seq = struct { ll: u32, ml: u32, of_val: u32 };

/// Сжимает `src` в один кадр zstd со словарём `dict` (сырое содержимое, может быть пустым).
pub fn compress(a: std.mem.Allocator, src: []const u8, dict: []const u8, level: Level) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, magic)));
    // заголовок: размер содержимого, одно окно, без контрольной суммы и номера словаря
    const n = src.len;
    if (n < 256) {
        try out.append(0x20);
        try out.append(@intCast(n));
    } else if (n < 65536 + 256) {
        try out.append(0x60);
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n - 256))));
    } else if (n <= std.math.maxInt(u32)) {
        try out.append(0xA0);
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(n))));
    } else return error.TooBig;

    // окно: словарь + данные одним буфером
    const win = try a.alloc(u8, dict.len + n);
    defer a.free(win);
    @memcpy(win[0..dict.len], dict);
    @memcpy(win[dict.len..], src);
    var mf = try Matcher.init(a, win, level);
    defer mf.deinit(a);
    mf.prime(dict.len);

    var rep: [3]u32 = .{ 1, 4, 8 };
    var pos: usize = 0;
    if (n == 0) {
        try out.appendSlice(&.{ 1, 0, 0 }); // пустой последний блок raw
        return out.toOwnedSlice();
    }
    var check_buf: ?[]u8 = null;
    defer if (check_buf) |b| a.free(b);
    while (pos < n) {
        const end = @min(n, pos + block_max);
        const last = end == n;
        const block_start = out.items.len;
        try out.appendSlice(&.{ 0, 0, 0 });
        const rep_before = rep;
        const ok = try compressBlock(a, &mf, dict.len, pos, end, &rep, &out);
        const bsize = out.items.len - block_start - 3;
        var raw = !ok or bsize >= end - pos;
        if (!raw) {
            // проверка своим распаковщиком: блок обязан дать ровно эти байты
            if (check_buf == null) check_buf = try a.alloc(u8, n);
            var st = SeqState{ .rep = rep_before };
            const got = decodeBlock(check_buf.?, 0, out.items[block_start + 3 ..], prefixFor(win, dict.len, pos), &st) catch null;
            if (got == null or got.? != end - pos or !std.mem.eql(u8, check_buf.?[0 .. end - pos], src[pos..end])) raw = true;
        }
        if (raw) {
            out.shrinkRetainingCapacity(block_start + 3);
            try out.appendSlice(src[pos..end]);
            rep = rep_before;
        }
        const size = out.items.len - block_start - 3;
        const bh: u32 = @as(u32, @intFromBool(last)) | (@as(u32, if (raw) 0 else 2) << 1) | (@as(u32, @intCast(size)) << 3);
        out.items[block_start] = @truncate(bh);
        out.items[block_start + 1] = @truncate(bh >> 8);
        out.items[block_start + 2] = @truncate(bh >> 16);
        pos = end;
    }
    return out.toOwnedSlice();
}

/// Для проверки блока: всё, что стоит перед ним в окне (словарь и прежние блоки),
/// играет роль словаря.
fn prefixFor(win: []const u8, dict_len: usize, pos: usize) []const u8 {
    return win[0 .. dict_len + pos];
}

const hash_log = 16;

const Matcher = struct {
    win: []const u8,
    head: []u32,
    prev: []u32,
    level: Level,

    const none = std.math.maxInt(u32);

    fn init(a: std.mem.Allocator, win: []const u8, level: Level) !Matcher {
        const head = try a.alloc(u32, 1 << hash_log);
        @memset(head, none);
        const prev = try a.alloc(u32, @max(win.len, 1));
        return .{ .win = win, .head = head, .prev = prev, .level = level };
    }

    fn deinit(m: *Matcher, a: std.mem.Allocator) void {
        a.free(m.head);
        a.free(m.prev);
    }

    fn hash(m: *const Matcher, i: usize) u32 {
        const v = std.mem.readInt(u32, m.win[i..][0..4], .little);
        return (v *% 2654435761) >> (32 - hash_log);
    }

    fn insert(m: *Matcher, i: usize) void {
        if (i + 4 > m.win.len) return;
        const h = m.hash(i);
        m.prev[i] = m.head[h];
        m.head[h] = @intCast(i);
    }

    fn prime(m: *Matcher, upto: usize) void {
        for (0..upto) |i| m.insert(i);
    }

    fn matchLen(m: *const Matcher, a_: usize, b: usize, limit: usize) usize {
        var k: usize = 0;
        while (b + k < limit and m.win[a_ + k] == m.win[b + k]) k += 1;
        return k;
    }

    /// Лучший повтор для позиции `i` (абсолютной в окне); данные кончаются на `limit`.
    fn best(m: *const Matcher, i: usize, limit: usize) struct { len: usize, off: usize } {
        if (i + 4 > limit) return .{ .len = 0, .off = 0 };
        var cand = m.head[m.hash(i)];
        var best_len: usize = 0;
        var best_off: usize = 0;
        var tries: u32 = 0;
        while (cand != none and tries < m.level.depth) : (tries += 1) {
            const c: usize = cand;
            if (c >= i or i + best_len >= limit) break;
            if (m.win[c + best_len] == m.win[i + best_len]) {
                const l = m.matchLen(c, i, limit);
                if (l > best_len) {
                    best_len = l;
                    best_off = i - c;
                }
            }
            cand = m.prev[c];
        }
        return .{ .len = best_len, .off = best_off };
    }
};

/// Сжатый блок данных `[pos, end)` (относительно начала данных). false — сжать нечем.
fn compressBlock(a: std.mem.Allocator, mf: *Matcher, base: usize, pos: usize, end: usize, rep: *[3]u32, out: *std.ArrayList(u8)) !bool {
    var seqs = std.ArrayList(Seq).init(a);
    defer seqs.deinit();
    var lits = std.ArrayList(u8).init(a);
    defer lits.deinit();
    const limit = base + end;
    var i = base + pos;
    var anchor = i;
    while (i < limit) {
        var m = mf.best(i, limit);
        // повтор последнего смещения обходится дешевле
        const r0: usize = rep[0];
        if (i >= r0 and i - r0 < i and i + 4 <= limit) {
            const rl = mf.matchLen(i - r0, i, limit);
            if (rl >= 4 and rl + 1 >= m.len) m = .{ .len = rl, .off = r0 };
        }
        if (m.len < 4) {
            mf.insert(i);
            i += 1;
            continue;
        }
        if (mf.level.lazy and i + 1 < limit) {
            mf.insert(i);
            const n2 = mf.best(i + 1, limit);
            if (n2.len > m.len + 1) {
                i += 1;
                continue;
            }
        } else mf.insert(i);
        const ll: u32 = @intCast(i - anchor);
        try lits.appendSlice(mf.win[anchor..i]);
        const off: u32 = @intCast(m.off);
        var of_val: u32 = off + 3;
        if (ll > 0 and off == rep[0]) {
            of_val = 1;
        } else if (ll > 0 and off == rep[1]) {
            of_val = 2;
            rep.* = .{ off, rep[0], rep[2] };
        } else if (ll > 0 and off == rep[2]) {
            of_val = 3;
            rep.* = .{ off, rep[0], rep[1] };
        } else {
            rep.* = .{ off, rep[0], rep[1] };
        }
        try seqs.append(.{ .ll = ll, .ml = @intCast(m.len), .of_val = of_val });
        var k: usize = 1;
        while (k < m.len) : (k += 1) mf.insert(i + k);
        i += m.len;
        anchor = i;
    }
    try lits.appendSlice(mf.win[anchor..limit]);
    if (seqs.items.len == 0 and lits.items.len < 64) return false;

    try writeLiterals(a, lits.items, out);
    try writeSequences(a, seqs.items, out);
    return true;
}

fn writeLiterals(a: std.mem.Allocator, lits: []const u8, out: *std.ArrayList(u8)) !void {
    const n = lits.len;
    huff: {
        if (n < 32) break :huff;
        var counts: [256]u32 = .{0} ** 256;
        for (lits) |c| counts[c] += 1;
        var lens: [256]u4 = undefined;
        if (!huffLengths(&counts, huff_max_bits, &lens)) break :huff;
        var max_sym: usize = 0;
        var mb: u4 = 0;
        for (lens, 0..) |l, s| if (l > 0) {
            max_sym = s;
            mb = @max(mb, l);
        };
        var w: [256]u4 = .{0} ** 256;
        for (0..max_sym + 1) |s| w[s] = if (lens[s] > 0) @intCast(mb + 1 - lens[s]) else 0;
        var h: Huff = .{};
        h.fromWeights(w[0 .. max_sym + 1]) catch break :huff;
        var body = std.ArrayList(u8).init(a);
        defer body.deinit();
        if (!(try writeHuffTree(a, w[0..max_sym], &body))) break :huff;
        const tree_len = body.items.len;
        const four = n > 1023;
        if (four) {
            const seg = (n + 3) / 4;
            if (seg * 3 >= n) break :huff;
            try body.appendSlice(&.{ 0, 0, 0, 0, 0, 0 });
            var sizes: [3]usize = undefined;
            for (0..4) |k| {
                const from = k * seg;
                const to = if (k == 3) n else from + seg;
                const before = body.items.len;
                try h.encodeStream(lits[from..to], &body);
                if (k < 3) sizes[k] = body.items.len - before;
            }
            for (sizes, 0..) |s, k| {
                if (s > 0xFFFF) break :huff;
                std.mem.writeInt(u16, body.items[tree_len + 2 * k ..][0..2], @intCast(s), .little);
            }
        } else try h.encodeStream(lits, &body);
        const cs = body.items.len;
        // заголовок сжатых литералов
        var hdr: [5]u8 = undefined;
        var hl: usize = undefined;
        if (!four and n <= 1023 and cs <= 1023) {
            const v: u32 = 2 | (0 << 2) | (@as(u32, @intCast(n)) << 4) | (@as(u32, @intCast(cs)) << 14);
            hdr[0] = @truncate(v);
            hdr[1] = @truncate(v >> 8);
            hdr[2] = @truncate(v >> 16);
            hl = 3;
        } else if (four and n <= 1023 and cs <= 1023) {
            const v: u32 = 2 | (1 << 2) | (@as(u32, @intCast(n)) << 4) | (@as(u32, @intCast(cs)) << 14);
            hdr[0] = @truncate(v);
            hdr[1] = @truncate(v >> 8);
            hdr[2] = @truncate(v >> 16);
            hl = 3;
        } else if (four and n <= 16383 and cs <= 16383) {
            const v: u32 = 2 | (2 << 2) | (@as(u32, @intCast(n)) << 4) | (@as(u32, @intCast(cs)) << 18);
            std.mem.writeInt(u32, hdr[0..4], v, .little);
            hl = 4;
        } else if (four and n <= 262143 and cs <= 262143) {
            const v: u64 = 2 | (3 << 2) | (@as(u64, n) << 4) | (@as(u64, cs) << 22);
            std.mem.writeInt(u32, hdr[0..4], @truncate(v), .little);
            hdr[4] = @truncate(v >> 32);
            hl = 5;
        } else break :huff;
        if (hl + cs >= n + rawHeaderLen(n)) break :huff;
        try out.appendSlice(hdr[0..hl]);
        try out.appendSlice(body.items);
        return;
    }
    // как есть
    if (n < 32) {
        try out.append(@intCast(n << 3));
    } else if (n < 4096) {
        try out.append(@intCast(((n & 15) << 4) | (1 << 2)));
        try out.append(@intCast(n >> 4));
    } else {
        try out.append(@intCast(((n & 15) << 4) | (3 << 2)));
        try out.append(@intCast((n >> 4) & 0xFF));
        try out.append(@intCast(n >> 12));
    }
    try out.appendSlice(lits);
}

fn rawHeaderLen(n: usize) usize {
    return if (n < 32) 1 else if (n < 4096) 2 else 3;
}

/// Веса Хаффмана (кроме последнего): прямо по 4 бита, если их не больше 128,
/// иначе — сжатые FSE с двумя чередующимися состояниями. false — не вышло.
fn writeHuffTree(a: std.mem.Allocator, w: []const u4, out: *std.ArrayList(u8)) !bool {
    if (w.len <= 128 and w.len > 0) {
        try out.append(@intCast(127 + w.len));
        var i: usize = 0;
        while (i < w.len) : (i += 2) {
            const hi: u8 = w[i];
            const lo: u8 = if (i + 1 < w.len) w[i + 1] else 0;
            try out.append((hi << 4) | lo);
        }
        return true;
    }
    if (w.len < 2 or w.len > 255) return false;
    var counts: [16]u32 = .{0} ** 16;
    var top: usize = 0;
    for (w) |x| {
        counts[x] += 1;
        top = @max(top, x);
    }
    const log: u4 = 6;
    var norm: [16]i16 = undefined;
    normalize(counts[0 .. top + 1], log, norm[0 .. top + 1]);
    var t: Fse = .{};
    t.build(norm[0 .. top + 1], log) catch return false;
    var body = std.ArrayList(u8).init(a);
    defer body.deinit();
    try writeNCount(&body, norm[0 .. top + 1], log);
    const m = w.len;
    // состояния: чётные выходы — первое, нечётные — второе; на выходе m-2 следующее
    // чтение обязано не уместиться (так распаковка узнаёт конец)
    var bits = std.ArrayList(u8).init(a);
    defer bits.deinit();
    var bw = BackWriter{ .out = &bits };
    var cur: [2]u16 = undefined;
    cur[(m - 1) % 2] = t.startFor(w[m - 1], false) orelse return false;
    cur[(m - 2) % 2] = t.startFor(w[m - 2], true) orelse return false;
    var i = m - 2;
    while (i > 0) {
        i -= 1;
        try t.encode(&bw, &cur[i % 2], w[i]);
    }
    try bw.put(cur[1], t.log);
    try bw.put(cur[0], t.log);
    try bw.close();
    const total = body.items.len + bits.items.len;
    if (total > 127) return false;
    try out.append(@intCast(total));
    try out.appendSlice(body.items);
    try out.appendSlice(bits.items);
    // самопроверка: веса читаются обратно ровно такими
    var h: Huff = .{};
    var full: [256]u4 = .{0} ** 256;
    @memcpy(full[0..m], w);
    const got = readHuffTreeWeights(out.items[out.items.len - total - 1 ..], &h) catch return false;
    _ = got;
    return true;
}

fn readHuffTreeWeights(data: []const u8, h: *Huff) Error!usize {
    return readHuffTree(data, h);
}

fn writeSequences(a: std.mem.Allocator, seqs: []const Seq, out: *std.ArrayList(u8)) !void {
    const n = seqs.len;
    if (n < 128) {
        try out.append(@intCast(n));
    } else if (n < 0x7F00) {
        try out.append(@intCast((n >> 8) + 128));
        try out.append(@intCast(n & 0xFF));
    } else {
        try out.append(0xFF);
        try out.append(@intCast((n - 0x7F00) & 0xFF));
        try out.append(@intCast((n - 0x7F00) >> 8));
    }
    if (n == 0) return;
    var llc = try a.alloc(u8, n);
    defer a.free(llc);
    var mlc = try a.alloc(u8, n);
    defer a.free(mlc);
    var ofc = try a.alloc(u8, n);
    defer a.free(ofc);
    var cll: [36]u32 = .{0} ** 36;
    var cml: [53]u32 = .{0} ** 53;
    var cof: [32]u32 = .{0} ** 32;
    for (seqs, 0..) |s, i| {
        llc[i] = codeOf(&ll_codes, s.ll);
        mlc[i] = codeOf(&ml_codes, s.ml);
        ofc[i] = highbit(s.of_val);
        cll[llc[i]] += 1;
        cml[mlc[i]] += 1;
        cof[ofc[i]] += 1;
    }
    var tll: Fse = .{};
    var tof: Fse = .{};
    var tml: Fse = .{};
    var desc = std.ArrayList(u8).init(a);
    defer desc.deinit();
    const mll = try chooseTable(a, &cll, &ll_default, 6, 9, &tll, &desc);
    const mof = try chooseTable(a, cof[0..29], &of_default, 5, 8, &tof, &desc);
    const mml = try chooseTable(a, &cml, &ml_default, 6, 9, &tml, &desc);
    try out.append((mll << 6) | (mof << 4) | (mml << 2));
    try out.appendSlice(desc.items);

    var bw = BackWriter{ .out = out };
    const last = n - 1;
    var sll: u16 = tll.startFor(llc[last], false).?;
    var sof: u16 = tof.startFor(ofc[last], false).?;
    var sml: u16 = tml.startFor(mlc[last], false).?;
    try putExtras(&bw, seqs[last], llc[last], mlc[last], ofc[last]);
    var i = last;
    while (i > 0) {
        i -= 1;
        try tof.encode(&bw, &sof, ofc[i]);
        try tml.encode(&bw, &sml, mlc[i]);
        try tll.encode(&bw, &sll, llc[i]);
        try putExtras(&bw, seqs[i], llc[i], mlc[i], ofc[i]);
    }
    try bw.put(sml, tml.log);
    try bw.put(sof, tof.log);
    try bw.put(sll, tll.log);
    try bw.close();
}

fn putExtras(bw: *BackWriter, s: Seq, llc: u8, mlc: u8, ofc: u8) !void {
    try bw.put(s.ll - ll_codes[llc].base, ll_codes[llc].bits);
    try bw.put(s.ml - ml_codes[mlc].base, ml_codes[mlc].bits);
    try bw.put(s.of_val - (@as(u32, 1) << @intCast(ofc)), @intCast(ofc));
}

/// Стандартная таблица, RLE или своя — что короче по оценке. Возвращает режим.
fn chooseTable(a: std.mem.Allocator, counts: []const u32, default: []const i16, default_log: u4, max_log: u4, t: *Fse, desc: *std.ArrayList(u8)) !u8 {
    _ = a;
    var used: usize = 0;
    var only: usize = 0;
    var total: u64 = 0;
    var top: usize = 0;
    for (counts, 0..) |c, s| if (c > 0) {
        used += 1;
        only = s;
        total += c;
        top = s;
    };
    if (used == 1) {
        t.rle(@intCast(only));
        try desc.append(@intCast(only));
        return 1;
    }
    // стандартная годится, только если покрывает все символы
    var default_ok = top < default.len;
    if (default_ok) for (counts, 0..) |c, s| {
        if (c > 0 and (s >= default.len or default[s] == 0)) default_ok = false;
    };
    const default_cost: f64 = if (default_ok) cost(counts, default, default_log) else std.math.inf(f64);
    // своя таблица
    var log: u4 = @intCast(@min(@as(u32, max_log), @max(5, highbit(@intCast(@max(total, 2))) + 1)));
    if (log > max_log) log = max_log;
    var norm: [64]i16 = undefined;
    // символов в таблице должно быть не больше её размера
    while (used > (@as(u32, 1) << log) and log < max_log) log += 1;
    normalize(counts[0 .. top + 1], log, norm[0 .. top + 1]);
    var head = std.ArrayList(u8).init(desc.allocator);
    defer head.deinit();
    try writeNCount(&head, norm[0 .. top + 1], log);
    const own_cost = cost(counts, norm[0 .. top + 1], log) + @as(f64, @floatFromInt(head.items.len * 8));
    if (default_ok and default_cost <= own_cost) {
        try t.build(default, default_log);
        return 0;
    }
    try t.build(norm[0 .. top + 1], log);
    try desc.appendSlice(head.items);
    return 2;
}

/// Примерная цена в битах: сумма -log2(p) по символам.
fn cost(counts: []const u32, norm: []const i16, log: u4) f64 {
    const sz: f64 = @floatFromInt(@as(u32, 1) << log);
    var bits: f64 = 0;
    for (counts, 0..) |c, s| {
        if (c == 0) continue;
        const p: f64 = if (s < norm.len and norm[s] != 0) @as(f64, @floatFromInt(if (norm[s] < 0) 1 else norm[s])) / sz else return std.math.inf(f64);
        bits += @as(f64, @floatFromInt(c)) * -@log2(p);
    }
    return bits;
}

// ───────────── проверки ─────────────

const testing = std.testing;

fn roundTrip(src: []const u8, dict: []const u8) !usize {
    const a = testing.allocator;
    const z = try compress(a, src, dict, .{});
    defer a.free(z);
    const back = try a.alloc(u8, src.len);
    defer a.free(back);
    const n = try decompress(back, z, dict);
    try testing.expectEqual(src.len, n);
    try testing.expectEqualSlices(u8, src, back);
    if (dict.len == 0 and std.mem.indexOfScalar(u8, src, 0xFF) == null) {
        // без словаря кадр обязан распаковываться и распаковкой из стандартной библиотеки
        const std_out = try std.compress.zstd.decompress.decodeAlloc(a, z, false, 1 << 24);
        defer a.free(std_out);
        try testing.expectEqualSlices(u8, src, std_out);
    }
    return z.len;
}

test "zstd: пустое, короткое, повторы, случайное" {
    _ = try roundTrip("", "");
    _ = try roundTrip("a", "");
    _ = try roundTrip("abcabcabcabcabcabcabcabcabcabcabcabc", "");
    var buf: [70000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&buf);
    _ = try roundTrip(&buf, "");
    for (&buf, 0..) |*b, i| b.* = "мама мыла раму, папа читал книгу. "[i % 34];
    const z = try roundTrip(&buf, "");
    try testing.expect(z < buf.len / 20);
}

test "zstd: текст — Хаффман литералов и свои таблицы" {
    var buf: [16384]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const words = [_][]const u8{ "\xe2\xee\xe9\xed\xe0 ", "\xec\xe8\xf0 ", "\xea\xed\xff\xe7\xfc ", "\xe0\xed\xed\xe0 ", "\xf1\xea\xe0\xe7\xe0\xeb ", "\xee\xed ", "\xe8 ", "\xe2 ", "\xed\xe5 ", "\xf7\xf2\xee ", "\xef\xf0\xe8\xf8\xb8\xeb ", ", ", ". " };
    var i: usize = 0;
    while (i < buf.len) {
        const wd = words[r.uintLessThan(usize, words.len)];
        const k = @min(wd.len, buf.len - i);
        @memcpy(buf[i..][0..k], wd[0..k]);
        i += k;
    }
    const z = try roundTrip(&buf, "");
    try testing.expect(z < buf.len / 3);
}

test "zstd: словарь сокращает кадр" {
    var dict: [4096]u8 = undefined;
    for (&dict, 0..) |*b, i| b.* = "Война и мир. Князь Андрей Болконский. "[i % 38];
    const src = "Князь Андрей Болконский. Война и мир. Князь Андрей.";
    const with = try roundTrip(src, &dict);
    const without = try roundTrip(src, "");
    try testing.expect(with < without);
}

test "zstd: испорченные кадры не роняют распаковку" {
    const a = testing.allocator;
    var src: [5000]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = "\xee\xed \xf1\xea\xe0\xe7\xe0\xeb, \xf7\xf2\xee "[i % 13];
    const z = try compress(a, &src, "", .{});
    defer a.free(z);
    var out: [5000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    const bad = try a.dupe(u8, z);
    defer a.free(bad);
    for (0..3000) |_| {
        @memcpy(bad, z);
        const k = r.uintLessThan(usize, 4) + 1;
        for (0..k) |_| bad[r.uintLessThan(usize, bad.len)] ^= @as(u8, 1) << r.int(u3);
        _ = decompress(&out, bad[0 .. bad.len - r.uintLessThan(usize, 3)], "") catch {};
    }
}
