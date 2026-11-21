//! GIF (87a/89a): первый кадр в RGBA8 (BACKLOG_RU.md §19). Анимация не берётся:
//! дальше картинка идёт как все — без прозрачности в JPEG, с ней в PNG.
//!
//! Кадр кладётся на холст логического экрана; вне кадра холст прозрачен (так
//! первый кадр показывают браузеры). Прозрачный цвет — из Graphic Control
//! Extension перед кадром. Разбор не доверяет входу: размеры проверяются до
//! выделений, коды LZW — по словарю, данных меньше — недостающее прозрачно.

const std = @import("std");
const Image = @import("image.zig").Image;

pub const Error = error{ NotGif, Damaged, TooBig, OutOfMemory };

pub fn looksLike(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a");
}

fn le16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}

/// Ширина и высота логического экрана.
pub fn size(bytes: []const u8) ?[2]u32 {
    if (!looksLike(bytes) or bytes.len < 10) return null;
    return .{ le16(bytes[6..]), le16(bytes[8..]) };
}

const Reader = struct {
    d: []const u8,
    i: usize,

    fn byte(r: *Reader) Error!u8 {
        if (r.i >= r.d.len) return error.Damaged;
        defer r.i += 1;
        return r.d[r.i];
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.d.len - r.i) return error.Damaged;
        defer r.i += n;
        return r.d[r.i..][0..n];
    }

    /// Пропуск подблоков до нулевого.
    fn skipBlocks(r: *Reader) Error!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }
};

/// Строка кадра для строки файла чересстрочного GIF: проходы 0/8, 4/8, 2/4, 1/2.
fn interlacedRow(ry: u32, h: u32) u32 {
    var r = ry;
    for ([_][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } }) |p| {
        const n = if (h > p[0]) (h - p[0] + p[1] - 1) / p[1] else 0;
        if (r < n) return p[0] + r * p[1];
        r -= n;
    }
    return ry;
}

/// Распаковка LZW в `out` (индексы цветов); возвращает, сколько записано.
fn lzw(data: []const u8, min_size: u8, out: []u8) usize {
    const clear: u16 = @as(u16, 1) << @intCast(min_size);
    const eoi = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var first: [4096]u8 = undefined; // первый байт цепочки кода
    var len: [4096]u16 = undefined; // длина цепочки
    for (0..clear) |k| {
        suffix[k] = @intCast(k);
        first[k] = @intCast(k);
        len[k] = 1;
        prefix[k] = 0;
    }
    var width: u5 = @intCast(min_size + 1);
    var next: u16 = eoi + 1;
    var prev: ?u16 = null;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var at: usize = 0;
    var n: usize = 0;
    while (n < out.len) {
        while (bits < width) {
            if (at >= data.len) return n;
            acc |= @as(u32, data[at]) << bits;
            at += 1;
            bits += 8;
        }
        const code: u16 = @intCast(acc & ((@as(u32, 1) << width) - 1));
        acc >>= width;
        bits -= width;
        if (code == clear) {
            width = @intCast(min_size + 1);
            next = eoi + 1;
            prev = null;
            continue;
        }
        if (code == eoi) return n;
        var cur = code;
        var head: u8 = undefined;
        if (code < next) {
            head = first[code];
        } else if (code == next and prev != null) {
            head = first[prev.?]; // KwKwK
        } else return n; // код вне словаря
        // новый код словаря: prev + первый байт текущего
        if (prev) |p| if (next < 4096) {
            prefix[next] = p;
            suffix[next] = head;
            first[next] = first[p];
            len[next] = len[p] + 1;
            next += 1;
            if (next == (@as(u16, 1) << @intCast(width)) and width < 12) width += 1;
        };
        // запись цепочки кода (с конца)
        const l = len[cur];
        if (n + l > out.len) {
            // хвост не влезает: пишем сколько можно
            var tmp: [4096]u8 = undefined;
            var k: usize = l;
            while (k > 0) {
                k -= 1;
                tmp[k] = suffix[cur];
                cur = prefix[cur];
            }
            const m = out.len - n;
            @memcpy(out[n..], tmp[0..m]);
            return out.len;
        }
        var k: usize = l;
        while (k > 0) {
            k -= 1;
            out[n + k] = suffix[cur];
            cur = prefix[cur];
        }
        n += l;
        prev = code;
    }
    return n;
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8, max_pixels: u64) Error!Image {
    if (!looksLike(bytes)) return error.NotGif;
    var r = Reader{ .d = bytes, .i = 6 };
    const sd = try r.take(7);
    const sw: u32 = le16(sd[0..]);
    const sh: u32 = le16(sd[2..]);
    const flags = sd[4];
    var gct: [256][3]u8 = undefined;
    var gct_n: usize = 0;
    if (flags & 0x80 != 0) {
        gct_n = @as(usize, 2) << @intCast(flags & 7);
        const t = try r.take(gct_n * 3);
        for (0..gct_n) |k| gct[k] = .{ t[k * 3], t[k * 3 + 1], t[k * 3 + 2] };
    }
    var transparent: ?u8 = null;
    while (true) {
        const tag = try r.byte();
        switch (tag) {
            0x21 => {
                const label = try r.byte();
                if (label == 0xF9) {
                    const n = try r.byte();
                    const g = try r.take(n);
                    if (n >= 4 and g[0] & 1 != 0) transparent = g[3];
                    try r.skipBlocks();
                } else try r.skipBlocks();
            },
            0x2C => {
                const id = try r.take(9);
                const fx: u32 = le16(id[0..]);
                const fy: u32 = le16(id[2..]);
                const fw: u32 = le16(id[4..]);
                const fh: u32 = le16(id[6..]);
                const iflags = id[8];
                // экран 0×0 бывает у старых кодировщиков: тогда холст — сам кадр
                const cw = if (sw == 0 or sh == 0) fx + fw else sw;
                const ch = if (sw == 0 or sh == 0) fy + fh else sh;
                if (cw == 0 or ch == 0 or fw == 0 or fh == 0) return error.Damaged;
                if (@as(u64, cw) * ch > max_pixels or @as(u64, fw) * fh > max_pixels) return error.TooBig;
                var pal = gct;
                var pal_n = gct_n;
                if (iflags & 0x80 != 0) {
                    pal_n = @as(usize, 2) << @intCast(iflags & 7);
                    const t = try r.take(pal_n * 3);
                    for (0..pal_n) |k| pal[k] = .{ t[k * 3], t[k * 3 + 1], t[k * 3 + 2] };
                }
                if (pal_n == 0) return error.Damaged;
                const min_size = try r.byte();
                if (min_size < 2 or min_size > 8) return error.Damaged;
                // подблоки данных → одна строка
                var data = std.ArrayList(u8).init(a);
                defer data.deinit();
                while (true) {
                    const n = try r.byte();
                    if (n == 0) break;
                    try data.appendSlice(try r.take(n));
                }
                const idx = try a.alloc(u8, @as(usize, fw) * fh);
                defer a.free(idx);
                const got = lzw(data.items, min_size, idx);
                const px = try a.alloc(u8, @as(usize, cw) * ch * 4);
                @memset(px, 0);
                for (0..fh) |ry_| {
                    const ry: u32 = @intCast(ry_);
                    const y = if (iflags & 0x40 != 0) interlacedRow(ry, fh) else ry;
                    const cy = fy + y;
                    if (cy >= ch) continue;
                    for (0..fw) |x| {
                        const k = ry * fw + x;
                        if (k >= got) break; // данных не хватило: дальше прозрачно
                        const cx = fx + @as(u32, @intCast(x));
                        if (cx >= cw) continue;
                        const ci = idx[k];
                        if (transparent != null and ci == transparent.?) continue;
                        const c = if (ci < pal_n) pal[ci] else [3]u8{ 0, 0, 0 };
                        px[(@as(usize, cy) * cw + cx) * 4 ..][0..4].* = .{ c[0], c[1], c[2], 255 };
                    }
                }
                return .{ .w = cw, .h = ch, .px = px };
            },
            0x3B => return error.Damaged, // конец файла без кадров
            else => return error.Damaged,
        }
    }
}

test "gif: свой кадр 4×3 с прозрачностью, чересстрочный и обычный" {
    const a = std.testing.allocator;
    // палитра: 0 — красный, 1 — зелёный, 2 — синий, 3 — прозрачный (GCE)
    // индексы кадра 4×3: 0 1 2 3 / 1 2 3 0 / 2 3 0 1; LZW без сжатия словаря: каждый код — сброс
    // через каждые несколько кодов, чтобы ширина кода осталась 3 бита.
    const idx = [_]u8{ 0, 1, 2, 3, 1, 2, 3, 0, 2, 3, 0, 1 };
    var bits = std.ArrayList(u8).init(a);
    defer bits.deinit();
    {
        var acc: u32 = 0;
        var n: u5 = 0;
        const put = struct {
            fn f(l: *std.ArrayList(u8), ac: *u32, nb: *u5, code: u32) !void {
                ac.* |= code << nb.*;
                nb.* += 3;
                while (nb.* >= 8) {
                    try l.append(@intCast(ac.* & 0xff));
                    ac.* >>= 8;
                    nb.* -= 8;
                }
            }
        }.f;
        // min_size 2: clear=4, eoi=5; после каждого литерала — сброс, ширина не растёт
        for (idx) |c| {
            try put(&bits, &acc, &n, 4);
            try put(&bits, &acc, &n, c);
        }
        try put(&bits, &acc, &n, 5);
        if (n > 0) try bits.append(@intCast(acc & 0xff));
    }
    for ([_]bool{ false, true }) |interlaced| {
        var f = std.ArrayList(u8).init(a);
        defer f.deinit();
        try f.appendSlice("GIF89a\x04\x00\x03\x00\x81\x00\x00");
        try f.appendSlice("\xff\x00\x00\x00\xff\x00\x00\x00\xff\x00\x00\x00");
        try f.appendSlice("\x21\xf9\x04\x01\x00\x00\x03\x00");
        try f.appendSlice("\x2c\x00\x00\x00\x00\x04\x00\x03\x00");
        try f.append(if (interlaced) 0x40 else 0);
        try f.append(2);
        try f.append(@intCast(bits.items.len));
        try f.appendSlice(bits.items);
        try f.appendSlice("\x00\x3b");
        const img = try decode(a, f.items, 1 << 20);
        defer a.free(img.px);
        try std.testing.expectEqual(@as(u32, 4), img.w);
        try std.testing.expectEqual(@as(u32, 3), img.h);
        const colors = [4][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 0, 0, 0, 0 } };
        // чересстрочный: строки файла 0,1,2 — это строки кадра 0,2,1
        const order = if (interlaced) [3]usize{ 0, 2, 1 } else [3]usize{ 0, 1, 2 };
        for (0..3) |fr| for (0..4) |x| {
            try std.testing.expectEqualSlices(u8, &colors[idx[fr * 4 + x]], img.px[(order[fr] * 4 + x) * 4 ..][0..4]);
        };
    }
}

test "gif: враждебный ввод" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotGif, decode(a, "PNG", 1 << 20));
    try std.testing.expectError(error.Damaged, decode(a, "GIF89a\x04\x00", 1 << 20));
    try std.testing.expectError(error.TooBig, decode(a, "GIF89a\xff\xff\xff\xff\x00\x00\x00\x2c\x00\x00\x00\x00\xff\xff\xff\xff\x00\x02\x00", 1 << 20));
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var buf: [300]u8 = undefined;
    for (0..5000) |_| {
        @memcpy(buf[0..6], "GIF89a");
        const n = rnd.intRangeAtMost(usize, 6, buf.len);
        for (buf[6..n]) |*c| c.* = rnd.int(u8);
        if (decode(a, buf[0..n], 1 << 16)) |im| a.free(im.px) else |_| {}
    }
}
