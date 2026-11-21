//! PNG (RFC 2083): разбор в RGBA8 и запись из RGBA8. Сжатие — zlib из std.
//!
//! Разбор не доверяет входу: все типы цвета и глубины, палитра и tRNS,
//! чересстрочность Adam7, проверка CRC каждого блока, предел по пикселям до
//! распаковки и точный размер распакованных данных — «бомба» не проходит.

const std = @import("std");
const Image = @import("image.zig").Image;

pub const signature = "\x89PNG\r\n\x1a\n";

pub const Error = error{ NotPng, Damaged, TooBig, Unsupported, OutOfMemory };

pub fn looksLike(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, signature);
}

const Header = struct { w: u32, h: u32, depth: u8, ctype: u8, interlace: u8 };

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// Каналов на пиксель для типа цвета.
fn channels(ctype: u8) u8 {
    return switch (ctype) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => 0,
    };
}

fn depthOk(ctype: u8, d: u8) bool {
    return switch (ctype) {
        0 => d == 1 or d == 2 or d == 4 or d == 8 or d == 16,
        3 => d == 1 or d == 2 or d == 4 or d == 8,
        2, 4, 6 => d == 8 or d == 16,
        else => false,
    };
}

/// Ширина и высота без разбора всего файла (для уже готовых картинок хранилища).
pub fn size(bytes: []const u8) ?[2]u32 {
    if (!looksLike(bytes) or bytes.len < 33 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{ be32(bytes[16..20]), be32(bytes[20..24]) };
}

const passes = [7][4]u8{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };

fn passDims(h: Header, p: usize) [2]u32 {
    if (h.interlace == 0) return .{ h.w, h.h };
    const x0, const y0, const dx, const dy = passes[p];
    const pw = if (h.w > x0) (h.w - x0 + dx - 1) / dx else 0;
    const ph = if (h.h > y0) (h.h - y0 + dy - 1) / dy else 0;
    return .{ pw, ph };
}

fn rowBytes(h: Header, w: u32) usize {
    return (@as(usize, w) * channels(h.ctype) * h.depth + 7) / 8;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn unfilter(ft: u8, row: []u8, prev: []const u8, bpp: usize) Error!void {
    switch (ft) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => for (row, prev) |*x, u| {
            x.* +%= u;
        },
        3 => for (row, 0..) |*x, i| {
            const left: u16 = if (i >= bpp) row[i - bpp] else 0;
            x.* +%= @intCast((left + prev[i]) / 2);
        },
        4 => for (row, 0..) |*x, i| {
            const left = if (i >= bpp) row[i - bpp] else 0;
            const ul = if (i >= bpp) prev[i - bpp] else 0;
            x.* +%= paeth(left, prev[i], ul);
        },
        else => return error.Damaged,
    }
}

/// Образец канала `k` пикселя `x` строки как 16-битное значение (для tRNS) и 8-битное.
fn sample(row: []const u8, depth: u8, idx: usize) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[idx * 2 ..][0..2], .big),
        8 => row[idx],
        else => blk: {
            const bit = idx * depth;
            const byte = row[bit / 8];
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :blk (byte >> shift) & mask;
        },
    };
}

fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8, max_pixels: u64) Error!Image {
    if (!looksLike(bytes)) return error.NotPng;
    var pos: usize = signature.len;
    var hdr: ?Header = null;
    var palette: [256][4]u8 = undefined;
    var n_pal: usize = 0;
    var trns: ?[3]u16 = null; // ключ прозрачности для типов 0 и 2
    var idat = std.ArrayList(u8).init(a);
    defer idat.deinit();
    var seen_end = false;
    while (pos + 12 <= bytes.len) {
        const len = be32(bytes[pos..]);
        if (len > bytes.len - pos - 12) return error.Damaged;
        const kind = bytes[pos + 4 .. pos + 8];
        const data = bytes[pos + 8 .. pos + 8 + len];
        const crc = be32(bytes[pos + 8 + len ..]);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.Damaged;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13 or hdr != null) return error.Damaged;
            const h = Header{ .w = be32(data[0..]), .h = be32(data[4..]), .depth = data[8], .ctype = data[9], .interlace = data[12] };
            if (h.w == 0 or h.h == 0 or h.w > 1 << 24 or h.h > 1 << 24) return error.Damaged;
            if (!depthOk(h.ctype, h.depth) or data[10] != 0 or data[11] != 0 or h.interlace > 1) return error.Unsupported;
            if (@as(u64, h.w) * h.h > max_pixels) return error.TooBig;
            hdr = h;
        } else if (hdr == null) {
            return error.Damaged; // IHDR — первый
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len / 3 > 256 or len == 0) return error.Damaged;
            n_pal = len / 3;
            for (0..n_pal) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (hdr.?.ctype) {
                3 => {
                    if (len > n_pal) return error.Damaged;
                    for (data, 0..) |al, i| palette[i][3] = al;
                },
                0 => {
                    if (len != 2) return error.Damaged;
                    const g = std.mem.readInt(u16, data[0..2], .big);
                    trns = .{ g, g, g };
                },
                2 => {
                    if (len != 6) return error.Damaged;
                    trns = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            seen_end = true;
            break;
        } else if (kind[0] & 0x20 == 0) {
            return error.Unsupported; // неизвестный обязательный блок
        }
    }
    const h = hdr orelse return error.Damaged;
    if (!seen_end or idat.items.len == 0) return error.Damaged;
    if (h.ctype == 3 and n_pal == 0) return error.Damaged;

    // точный размер распакованного: строки всех проходов с байтом фильтра
    var raw_len: u64 = 0;
    const n_pass: usize = if (h.interlace == 1) 7 else 1;
    for (0..n_pass) |p| {
        const pw, const ph = passDims(h, p);
        if (pw == 0 or ph == 0) continue;
        raw_len += @as(u64, ph) * (1 + rowBytes(h, pw));
    }
    if (raw_len > 1 << 31) return error.TooBig;
    const raw = try a.alloc(u8, @intCast(raw_len + 1));
    defer a.free(raw);
    var in = std.io.fixedBufferStream(idat.items);
    var out = std.io.fixedBufferStream(raw);
    std.compress.zlib.decompress(in.reader(), out.writer()) catch return error.Damaged;
    if (out.pos != raw_len) return error.Damaged;

    const px = try a.alloc(u8, @as(usize, h.w) * h.h * 4);
    errdefer a.free(px);
    const ch = channels(h.ctype);
    const bpp = @max(1, (@as(usize, ch) * h.depth) / 8);
    const prev_buf = try a.alloc(u8, rowBytes(h, h.w));
    defer a.free(prev_buf);
    var at: usize = 0;
    for (0..n_pass) |p| {
        const pw, const ph = passDims(h, p);
        if (pw == 0 or ph == 0) continue;
        const rb = rowBytes(h, pw);
        const prev = prev_buf[0..rb];
        @memset(prev, 0);
        const x0: u32, const y0: u32, const dx: u32, const dy: u32 = if (h.interlace == 1) .{ passes[p][0], passes[p][1], passes[p][2], passes[p][3] } else .{ 0, 0, 1, 1 };
        for (0..ph) |ry| {
            const ft = raw[at];
            const row = raw[at + 1 .. at + 1 + rb];
            at += 1 + rb;
            try unfilter(ft, row, prev, bpp);
            @memcpy(prev, row);
            const y = y0 + @as(u32, @intCast(ry)) * dy;
            for (0..pw) |rx| {
                const x = x0 + @as(u32, @intCast(rx)) * dx;
                const o = (@as(usize, y) * h.w + x) * 4;
                const d = px[o..][0..4];
                const base = rx * ch;
                switch (h.ctype) {
                    3 => {
                        const i = sample(row, h.depth, base);
                        if (i >= n_pal) return error.Damaged;
                        d.* = palette[i];
                    },
                    0, 4 => {
                        const g = sample(row, h.depth, base);
                        const v = to8(g, h.depth);
                        d.* = .{ v, v, v, 255 };
                        if (h.ctype == 4) d[3] = to8(sample(row, h.depth, base + 1), h.depth) else if (trns) |t| {
                            if (g == t[0]) d[3] = 0;
                        }
                    },
                    2, 6 => {
                        const r = sample(row, h.depth, base);
                        const g = sample(row, h.depth, base + 1);
                        const b = sample(row, h.depth, base + 2);
                        d.* = .{ to8(r, h.depth), to8(g, h.depth), to8(b, h.depth), 255 };
                        if (h.ctype == 6) d[3] = to8(sample(row, h.depth, base + 3), h.depth) else if (trns) |t| {
                            if (r == t[0] and g == t[1] and b == t[2]) d[3] = 0;
                        }
                    },
                    else => unreachable,
                }
            }
        }
    }
    return .{ .w = h.w, .h = h.h, .px = px };
}

fn chunk(out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    try out.writer().writeInt(u32, @intCast(data.len), .big);
    const start = out.items.len;
    try out.appendSlice(kind);
    try out.appendSlice(data);
    try out.writer().writeInt(u32, std.hash.Crc32.hash(out.items[start..]), .big);
}

/// Записывает RGBA8; без прозрачности — RGB. Фильтр строки — с наименьшей суммой.
pub fn encode(a: std.mem.Allocator, img: Image) ![]u8 {
    var opaque_ = true;
    var i: usize = 3;
    while (i < img.px.len) : (i += 4) if (img.px[i] != 255) {
        opaque_ = false;
        break;
    };
    const ch: usize = if (opaque_) 3 else 4;
    const rb = @as(usize, img.w) * ch;
    var raw = try a.alloc(u8, (rb + 1) * img.h);
    defer a.free(raw);
    const cur = try a.alloc(u8, rb);
    defer a.free(cur);
    const prev = try a.alloc(u8, rb);
    defer a.free(prev);
    const trial = try a.alloc(u8, rb);
    defer a.free(trial);
    @memset(prev, 0);
    for (0..img.h) |y| {
        for (0..img.w) |x| @memcpy(cur[x * ch ..][0..ch], img.px[(y * img.w + x) * 4 ..][0..ch]);

        var best_sum: u64 = std.math.maxInt(u64);
        const dst = raw[y * (rb + 1) ..][0 .. rb + 1];
        for (0..5) |ft_| {
            const ft: u8 = @intCast(ft_);
            var sum: u64 = 0;
            for (0..rb) |k| {
                const left: u8 = if (k >= ch) cur[k - ch] else 0;
                const ul: u8 = if (k >= ch) prev[k - ch] else 0;
                const pred: u8 = switch (ft) {
                    0 => 0,
                    1 => left,
                    2 => prev[k],
                    3 => @intCast((@as(u16, left) + prev[k]) / 2),
                    else => paeth(left, prev[k], ul),
                };
                const v = cur[k] -% pred;
                trial[k] = v;
                sum += @abs(@as(i8, @bitCast(v)));
            }
            if (sum < best_sum) {
                best_sum = sum;

                dst[0] = ft;
                @memcpy(dst[1..], trial);
            }
        }
        @memcpy(prev, cur);
    }
    var z = std.ArrayList(u8).init(a);
    defer z.deinit();
    var in = std.io.fixedBufferStream(raw);
    try std.compress.zlib.compress(in.reader(), z.writer(), .{ .level = .best });
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.h, .big);
    ihdr[8] = 8;
    ihdr[9] = if (opaque_) 2 else 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, "IHDR", &ihdr);
    try chunk(&out, "IDAT", z.items);
    try chunk(&out, "IEND", "");
    return out.toOwnedSlice();
}

test "png: запись и разбор туда и обратно, прозрачность сохраняется" {
    const a = std.testing.allocator;
    var px: [7 * 5 * 4]u8 = undefined;
    for (0..35) |k| px[k * 4 ..][0..4].* = .{ @intCast(k * 7), @intCast(255 - k), @intCast(k * 3), if (k % 4 == 0) 0 else 200 };
    const img = Image{ .w = 7, .h = 5, .px = &px };
    const f = try encode(a, img);
    defer a.free(f);
    try std.testing.expectEqual([2]u32{ 7, 5 }, size(f).?);
    const back = try decode(a, f, 1 << 20);
    defer a.free(back.px);
    try std.testing.expectEqualSlices(u8, &px, back.px);
}

test "png: враждебный ввод" {
    const a = std.testing.allocator;
    var px: [16 * 16 * 4]u8 = undefined;
    for (&px, 0..) |*b, k| b.* = @intCast(k % 251);
    const f = try encode(a, .{ .w = 16, .h = 16, .px = &px });
    defer a.free(f);
    // предел пикселей
    try std.testing.expectError(error.TooBig, decode(a, f, 100));
    // обрезки и порча байтов
    for (0..f.len) |n| if (decode(a, f[0..n], 1 << 20)) |im| a.free(im.px) else |_| {};
    const bad = try a.dupe(u8, f);
    defer a.free(bad);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..2000) |_| {
        @memcpy(bad, f);
        for (0..rnd.intRangeAtMost(usize, 1, 4)) |_| bad[rnd.uintLessThan(usize, bad.len)] = rnd.int(u8);
        if (decode(a, bad, 1 << 20)) |im| a.free(im.px) else |_| {}
    }
}
