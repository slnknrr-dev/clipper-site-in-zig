//! Картинки книг (BACKLOG_RU.md §17, §19): разбор PNG, JPEG, GIF (первый кадр) и WebP,
//! растеризация SVG, уменьшение до места на странице и запись. Без прозрачности —
//! JPEG (меньше), с прозрачностью — PNG; SVG — всегда PNG.

const std = @import("std");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const gif = @import("gif.zig");
const webp = @import("webp.zig");
const svg = @import("svg.zig");

/// Пиксели RGBA8 построчно.
pub const Image = struct { w: u32, h: u32, px: []u8 };

/// Место картинки на странице: вписывается целиком, маленькая не растягивается.
pub const box_w = 800;
pub const box_h = 600;
pub const jpeg_quality = 80;
/// Больше 12 Мп не разбирается: памяти на разбор нужно около 12 байт на пиксель.
pub const max_pixels = 12 * 1024 * 1024;

pub const Kind = enum(u8) { jpg = 1, png = 2 };

pub fn ext(k: Kind) []const u8 {
    return if (k == .jpg) ".jpg" else ".png";
}

pub fn mime(k: Kind) []const u8 {
    return if (k == .jpg) "image/jpeg" else "image/png";
}

/// Готовая картинка: байты файла, вид и размер.
pub const Out = struct { bytes: []u8, kind: Kind, w: u32, h: u32 };

pub const Error = error{ NotImage, Damaged, TooBig, Unsupported, OutOfMemory };

/// Вид и размер готового файла хранилища без разбора.
pub fn info(bytes: []const u8) ?struct { Kind, u32, u32 } {
    if (png.size(bytes)) |s| return .{ .png, s[0], s[1] };
    if (jpeg.size(bytes)) |s| return .{ .jpg, s[0], s[1] };
    return null;
}

/// Размер, вписанный в место `bw`×`bh` с сохранением пропорций; не больше исходного.
pub fn fit(w: u32, h: u32, bw: u32, bh: u32) [2]u32 {
    if (w <= bw and h <= bh) return .{ w, h };
    // сравнение w/bw и h/bh без дробей
    if (@as(u64, w) * bh >= @as(u64, h) * bw) {
        return .{ bw, @intCast(@max(1, (@as(u64, h) * bw + w / 2) / w)) };
    }
    return .{ @intCast(@max(1, (@as(u64, w) * bh + h / 2) / h)), bh };
}

/// Уменьшение усреднением по площади: каждый пиксель результата — среднее
/// покрытой им области исходника (с долями крайних пикселей). Цвет усредняется
/// с весом альфы, чтобы у прозрачных краёв не было тёмной каймы.
pub fn resize(a: std.mem.Allocator, src: Image, w: u32, h: u32) !Image {
    const px = try a.alloc(u8, @as(usize, w) * h * 4);
    const sx: f64 = @as(f64, @floatFromInt(src.w)) / @as(f64, @floatFromInt(w));
    const sy: f64 = @as(f64, @floatFromInt(src.h)) / @as(f64, @floatFromInt(h));
    for (0..h) |y| {
        const y0 = @as(f64, @floatFromInt(y)) * sy;
        const y1 = y0 + sy;
        for (0..w) |x| {
            const x0 = @as(f64, @floatFromInt(x)) * sx;
            const x1 = x0 + sx;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var area: f64 = 0;
            var yy: usize = @intFromFloat(@floor(y0));
            while (yy < src.h and @as(f64, @floatFromInt(yy)) < y1) : (yy += 1) {
                const fy = @min(y1, @as(f64, @floatFromInt(yy + 1))) - @max(y0, @as(f64, @floatFromInt(yy)));
                var xx: usize = @intFromFloat(@floor(x0));
                while (xx < src.w and @as(f64, @floatFromInt(xx)) < x1) : (xx += 1) {
                    const fx = @min(x1, @as(f64, @floatFromInt(xx + 1))) - @max(x0, @as(f64, @floatFromInt(xx)));
                    const wgt = fx * fy;
                    const p = src.px[(yy * src.w + xx) * 4 ..][0..4];
                    const al = @as(f64, @floatFromInt(p[3])) / 255.0;
                    for (0..3) |k| acc[k] += @as(f64, @floatFromInt(p[k])) * al * wgt;
                    acc[3] += al * wgt;
                    area += wgt;
                }
            }
            const d = px[(y * w + x) * 4 ..][0..4];
            if (acc[3] > 0) {
                for (0..3) |k| d[k] = @intFromFloat(std.math.clamp(@round(acc[k] / acc[3]), 0, 255));
            } else d[0..3].* = .{ 0, 0, 0 };
            d[3] = @intFromFloat(std.math.clamp(@round(acc[3] / @max(area, 1e-9) * 255.0), 0, 255));
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

pub fn hasAlpha(img: Image) bool {
    var i: usize = 3;
    while (i < img.px.len) : (i += 4) if (img.px[i] != 255) return true;
    return false;
}

fn mapErr(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooBig => error.TooBig,
        error.Unsupported => error.Unsupported,
        error.NotPng, error.NotJpeg, error.NotGif, error.NotWebp, error.NotSvg => error.NotImage,
        else => error.Damaged,
    };
}

/// Разбор растровой картинки любого из четырёх видов в RGBA8.
pub fn decodeAny(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (png.looksLike(bytes)) return png.decode(a, bytes, max_pixels) catch |e| mapErr(e);
    if (jpeg.looksLike(bytes)) return jpeg.decode(a, bytes, max_pixels) catch |e| mapErr(e);
    if (gif.looksLike(bytes)) return gif.decode(a, bytes, max_pixels) catch |e| mapErr(e);
    if (webp.looksLike(bytes)) return webp.decode(a, bytes, max_pixels) catch |e| mapErr(e);
    return error.NotImage;
}

/// Картинка книги → готовый файл: разбор (или растеризация SVG), уменьшение до места, запись.
pub fn process(a: std.mem.Allocator, bytes: []const u8) Error!Out {
    if (svg.looksLike(bytes)) {
        // вектор: рисуется сразу в своём размере, вписанном в место; всегда PNG
        const img = svg.render(a, bytes, box_w, box_h) catch |e| return mapErr(e);
        defer a.free(img.px);
        return .{ .bytes = png.encode(a, img) catch return error.OutOfMemory, .kind = .png, .w = img.w, .h = img.h };
    }
    const src = try decodeAny(a, bytes);
    defer a.free(src.px);
    const w, const h = fit(src.w, src.h, box_w, box_h);
    const img = if (w == src.w and h == src.h) src else try resize(a, src, w, h);
    defer if (img.px.ptr != src.px.ptr) a.free(img.px);
    if (hasAlpha(img)) {
        return .{ .bytes = png.encode(a, img) catch return error.OutOfMemory, .kind = .png, .w = w, .h = h };
    }
    return .{ .bytes = jpeg.encode(a, img, jpeg_quality) catch return error.OutOfMemory, .kind = .jpg, .w = w, .h = h };
}

test "вписывание в место" {
    try std.testing.expectEqual([2]u32{ 800, 400 }, fit(2000, 1000, 800, 600));
    try std.testing.expectEqual([2]u32{ 300, 600 }, fit(1000, 2000, 800, 600));
    try std.testing.expectEqual([2]u32{ 800, 600 }, fit(1600, 1200, 800, 600));
    try std.testing.expectEqual([2]u32{ 100, 50 }, fit(100, 50, 800, 600));
    try std.testing.expectEqual([2]u32{ 800, 1 }, fit(100000, 10, 800, 600));
}

test "картинка: прозрачная — PNG, непрозрачная — JPEG, большая уменьшается" {
    const a = std.testing.allocator;
    const W = 1600;
    const H = 400;
    const px = try a.alloc(u8, W * H * 4);
    defer a.free(px);
    for (0..H) |y| for (0..W) |x| {
        px[(y * W + x) * 4 ..][0..4].* = .{ @intCast(x % 256), @intCast(y % 256), 128, 255 };
    };
    const opaque_png = try png.encode(a, .{ .w = W, .h = H, .px = px });
    defer a.free(opaque_png);
    const o = try process(a, opaque_png);
    defer a.free(o.bytes);
    try std.testing.expectEqual(Kind.jpg, o.kind);
    try std.testing.expectEqual([2]u32{ 800, 200 }, [2]u32{ o.w, o.h });
    try std.testing.expectEqual(Kind.jpg, info(o.bytes).?[0]);
    px[3] = 0; // один прозрачный пиксель
    const clear_png = try png.encode(a, .{ .w = W, .h = H, .px = px });
    defer a.free(clear_png);
    const t = try process(a, clear_png);
    defer a.free(t.bytes);
    try std.testing.expectEqual(Kind.png, t.kind);
    try std.testing.expectEqual(@as(u32, 800), info(t.bytes).?[1]);
    try std.testing.expectError(error.Damaged, process(a, "GIF89a"));
    try std.testing.expectError(error.NotImage, process(a, "BM"));
    // SVG — всегда PNG, в своём размере
    const v = try process(a, "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='navy'/></svg>");
    defer a.free(v.bytes);
    try std.testing.expectEqual(Kind.png, v.kind);
    try std.testing.expectEqual([2]u32{ 40, 20 }, [2]u32{ v.w, v.h });
}
