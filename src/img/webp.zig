//! WebP: контейнер RIFF → RGBA8 (BACKLOG_RU.md §19). Простой формат (VP8 или VP8L),
//! расширенный (VP8X: альфа ALPH к VP8), анимация — первый кадр ANMF на
//! прозрачном холсте. Дальше картинка идёт как все: без прозрачности — JPEG,
//! с ней — PNG.
//!
//! YUV → RGB — теми же целыми, что в libwebp, с «мягким» растяжением цветности
//! (9-3-3-1): так картинка совпадает с тем, что показывают браузеры.

const std = @import("std");
const Image = @import("image.zig").Image;
const vp8 = @import("vp8.zig");
const vp8l = @import("vp8l.zig");

pub const Error = error{ NotWebp, Damaged, TooBig, Unsupported, OutOfMemory };

pub fn looksLike(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
}

const Chunk = struct { id: [4]u8, data: []const u8 };

const Chunks = struct {
    d: []const u8,
    i: usize,

    fn next(c: *Chunks) Error!?Chunk {
        if (c.i + 8 > c.d.len) return null;
        const id = c.d[c.i..][0..4].*;
        const n = std.mem.readInt(u32, c.d[c.i + 4 ..][0..4], .little);
        if (n > c.d.len - c.i - 8) return error.Damaged;
        const data = c.d[c.i + 8 ..][0..n];
        c.i += 8 + n + (n & 1);
        return .{ .id = id, .data = data };
    }
};

fn le24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// Ширина и высота без разбора.
pub fn size(bytes: []const u8) ?[2]u32 {
    if (!looksLike(bytes)) return null;
    var c = Chunks{ .d = bytes, .i = 12 };
    while (c.next() catch return null) |ch| {
        if (std.mem.eql(u8, &ch.id, "VP8X") and ch.data.len >= 10) return .{ le24(ch.data[4..]) + 1, le24(ch.data[7..]) + 1 };
        if (std.mem.eql(u8, &ch.id, "VP8L")) if (vp8l.header(ch.data)) |h| return .{ h.w, h.h };
        if (std.mem.eql(u8, &ch.id, "VP8 ")) if (ch.data.len >= 10) if (vp8.size(ch.data)) |s| return s;
    }
    return null;
}

fn mulHi(v: i32, c: i32) i32 {
    return (v * c) >> 8;
}

fn clip8(v: i32) u8 {
    return if (v & ~@as(i32, 16383) == 0) @intCast(v >> 6) else if (v < 0) 0 else 255;
}

fn yuvToRgb(y: i32, u: i32, v: i32, out: *[4]u8) void {
    out[0] = clip8(mulHi(y, 19077) + mulHi(v, 26149) - 14234);
    out[1] = clip8(mulHi(y, 19077) - mulHi(u, 6419) - mulHi(v, 13320) + 8708);
    out[2] = clip8(mulHi(y, 19077) + mulHi(u, 33050) - 17685);
    out[3] = 255;
}

/// Строка яркости `yr` с цветностью ближней строки `n` и дальней `f` (обе — строки U или V).
fn upsampleRow(yr: []const u8, nu: []const u8, nv: []const u8, fu: []const u8, fv: []const u8, w: usize, out: []u8) void {
    const load = struct {
        fn f(u: []const u8, v: []const u8, x: usize) u32 {
            return @as(u32, u[x]) | (@as(u32, v[x]) << 16);
        }
    }.f;
    const put = struct {
        fn f(y: u8, uv: u32, o: []u8) void {
            yuvToRgb(y, @intCast(uv & 0xff), @intCast((uv >> 16) & 0xff), o[0..4]);
        }
    }.f;
    var tl = load(nu, nv, 0); // ближняя, левая
    var l = load(fu, fv, 0); // дальняя, левая
    put(yr[0], (3 * tl + l + 0x00020002) >> 2, out[0..]);
    const last_pair = (w - 1) >> 1;
    var x: usize = 1;
    while (x <= last_pair) : (x += 1) {
        const t = load(nu, nv, x);
        const uv = load(fu, fv, x);
        const avg = tl + t + l + uv + 0x00080008;
        const diag_12 = (avg + 2 * (t + l)) >> 3;
        const diag_03 = (avg + 2 * (tl + uv)) >> 3;
        put(yr[2 * x - 1], (diag_12 + tl) >> 1, out[(2 * x - 1) * 4 ..]);
        put(yr[2 * x], (diag_03 + t) >> 1, out[(2 * x) * 4 ..]);
        tl = t;
        l = uv;
    }
    if (w & 1 == 0) put(yr[w - 1], (3 * tl + l + 0x00020002) >> 2, out[(w - 1) * 4 ..]);
}

fn lossy(a: std.mem.Allocator, data: []const u8, max_pixels: u64) Error!Image {
    const f = vp8.decode(a, data, max_pixels) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooBig => error.TooBig,
        error.Unsupported => error.Unsupported,
        error.Damaged => error.Damaged,
    };
    defer {
        a.free(f.y);
        a.free(f.u);
        a.free(f.v);
    }
    const w: usize = f.w;
    const h: usize = f.h;
    const px = try a.alloc(u8, w * h * 4);
    const uvh = (h + 1) / 2;
    for (0..h) |y| {
        // строка 0 — сама с собой; нечётная 2k+1 — ближняя k, дальняя k+1; чётная 2k+2 — наоборот
        var near: usize = 0;
        var far: usize = 0;
        if (y > 0) {
            const k = (y - 1) / 2;
            if (y % 2 == 1) {
                near = k;
                far = @min(k + 1, uvh - 1);
            } else {
                near = k + 1;
                far = k;
            }
        }
        upsampleRow(f.y[y * f.y_stride ..], f.u[near * f.uv_stride ..], f.v[near * f.uv_stride ..], f.u[far * f.uv_stride ..], f.v[far * f.uv_stride ..], w, px[y * w * 4 ..]);
    }
    return .{ .w = f.w, .h = f.h, .px = px };
}

fn lossless(a: std.mem.Allocator, data: []const u8, max_pixels: u64) Error!Image {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const r = vp8l.decode(arena.allocator(), data, max_pixels) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooBig => error.TooBig,
        error.Damaged => error.Damaged,
    };
    const px = try a.alloc(u8, r.argb.len * 4);
    for (r.argb, 0..) |p, k| px[k * 4 ..][0..4].* = .{ @intCast((p >> 16) & 0xff), @intCast((p >> 8) & 0xff), @intCast(p & 0xff), @intCast(p >> 24) };
    return .{ .w = r.w, .h = r.h, .px = px };
}

/// Альфа-канал ALPH к картинке с потерями: сырой или VP8L (зелёный канал), с фильтром.
fn applyAlpha(a: std.mem.Allocator, img: Image, alph: []const u8) Error!void {
    if (alph.len < 1) return error.Damaged;
    const hdr = alph[0];
    const method = hdr & 3;
    const filter = (hdr >> 2) & 3;
    const w: usize = img.w;
    const h: usize = img.h;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const in = try aa.alloc(u8, w * h);
    switch (method) {
        0 => {
            if (alph.len - 1 < w * h) return error.Damaged;
            @memcpy(in, alph[1..][0 .. w * h]);
        },
        1 => {
            const argb = vp8l.decodeStream(aa, alph[1..], img.w, img.h, 1 << 32) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Damaged,
            };
            for (argb, in) |p, *o| o.* = @intCast((p >> 8) & 0xff);
        },
        else => return error.Damaged,
    }
    // обратный фильтр: по строкам, предыдущая строка уже восстановлена
    const out = try aa.alloc(u8, w * h);
    for (0..h) |y| {
        const row = in[y * w ..][0..w];
        const o = out[y * w ..][0..w];
        const prev: ?[]const u8 = if (y > 0) out[(y - 1) * w ..][0..w] else null;
        switch (filter) {
            0 => @memcpy(o, row),
            1 => horizontal(prev, row, o),
            2 => if (prev) |p| {
                for (o, row, p) |*d, r, t| d.* = r +% t;
            } else horizontal(null, row, o),
            else => if (prev) |p| {
                var top = p[0];
                var top_left = top;
                var left = top;
                for (0..w) |x| {
                    top = p[x];
                    const g = std.math.clamp(@as(i32, left) + top - top_left, 0, 255);
                    left = row[x] +% @as(u8, @intCast(g));
                    top_left = top;
                    o[x] = left;
                }
            } else horizontal(null, row, o),
        }
    }
    for (0..w * h) |k| img.px[k * 4 + 3] = out[k];
}

fn horizontal(prev: ?[]const u8, row: []const u8, o: []u8) void {
    var pred: u8 = if (prev) |p| p[0] else 0;
    for (row, o) |r, *d| {
        d.* = pred +% r;
        pred = d.*;
    }
}

/// Кадр: VP8L или VP8 (+ ALPH).
fn frame(a: std.mem.Allocator, chunks: *Chunks, max_pixels: u64) Error!?Image {
    var alph: ?[]const u8 = null;
    while (try chunks.next()) |ch| {
        if (std.mem.eql(u8, &ch.id, "ALPH")) alph = ch.data;
        if (std.mem.eql(u8, &ch.id, "VP8L")) return try lossless(a, ch.data, max_pixels);
        if (std.mem.eql(u8, &ch.id, "VP8 ")) {
            const img = try lossy(a, ch.data, max_pixels);
            errdefer a.free(img.px);
            if (alph) |al| try applyAlpha(a, img, al);
            return img;
        }
    }
    return null;
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8, max_pixels: u64) Error!Image {
    if (!looksLike(bytes)) return error.NotWebp;
    const riff = std.mem.readInt(u32, bytes[4..8], .little);
    const end = @min(bytes.len, @as(usize, riff) + 8);
    var c = Chunks{ .d = bytes[0..end], .i = 12 };
    // анимация: первый ANMF на прозрачном холсте VP8X
    var canvas: ?[2]u32 = null;
    var probe = c;
    while (try probe.next()) |ch| {
        if (std.mem.eql(u8, &ch.id, "VP8X")) {
            if (ch.data.len < 10) return error.Damaged;
            canvas = .{ le24(ch.data[4..]) + 1, le24(ch.data[7..]) + 1 };
        }
        if (std.mem.eql(u8, &ch.id, "ANMF")) {
            const cv = canvas orelse return error.Damaged;
            if (ch.data.len < 16) return error.Damaged;
            if (@as(u64, cv[0]) * cv[1] > max_pixels) return error.TooBig;
            const fx = le24(ch.data[0..]) * 2;
            const fy = le24(ch.data[3..]) * 2;
            var sub = Chunks{ .d = ch.data, .i = 16 };
            const fr = (try frame(a, &sub, max_pixels)) orelse return error.Damaged;
            defer a.free(fr.px);
            const px = try a.alloc(u8, @as(usize, cv[0]) * cv[1] * 4);
            @memset(px, 0);
            for (0..fr.h) |y| for (0..fr.w) |x| {
                const cx = fx + x;
                const cy = fy + y;
                if (cx >= cv[0] or cy >= cv[1]) continue;
                @memcpy(px[(cy * cv[0] + cx) * 4 ..][0..4], fr.px[(y * fr.w + x) * 4 ..][0..4]);
            };
            return .{ .w = cv[0], .h = cv[1], .px = px };
        }
    }
    return (try frame(a, &c, max_pixels)) orelse error.Damaged;
}

test "webp: враждебный ввод" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotWebp, decode(a, "RIFF", 1 << 20));
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    var buf: [400]u8 = undefined;
    const heads = [_][]const u8{ "RIFF\x00\x01\x00\x00WEBPVP8L\x80\x00\x00\x00\x2f", "RIFF\x00\x01\x00\x00WEBPVP8 \x80\x00\x00\x00\x10\x02\x00\x9d\x01\x2a\x10\x00\x10\x00" };
    for (0..6000) |k| {
        const hd = heads[k % 2];
        @memcpy(buf[0..hd.len], hd);
        const n = rnd.intRangeAtMost(usize, hd.len, buf.len);
        for (buf[hd.len..n]) |*c| c.* = rnd.int(u8);
        if (decode(a, buf[0..n], 1 << 16)) |im| a.free(im.px) else |_| {}
    }
}
