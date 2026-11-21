//! Хранилище картинок книг `img/b/` (BACKLOG_RU.md §17; img — папка -img или ROOTDIR/img): общее для всех поколений
//! снимка. Имя файла — отпечаток исходной картинки и правил обработки:
//! картинка разбирается и пережимается один раз, при первой сборке, где её
//! книга встретилась; дальше сборки только находят готовый файл. Одинаковые
//! картинки разных книг лежат одним файлом.

const std = @import("std");
const image = @import("img/image.zig");
const snapshot = @import("snapshot.zig");
const fb2 = @import("fb2.zig");

/// Подпапка картинок книг в папке картинок.
pub const dir_name = "b";

/// Отпечаток исходника вместе с правилами (место, качество): правила
/// сменились — картинки обрабатываются заново.
pub fn hashOf(src: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x696d67);
    const rules = [_]u32{ image.box_w, image.box_h, image.jpeg_quality, 1 };
    h.update(std.mem.asBytes(&rules));
    h.update(src);
    return h.final();
}

/// Имя файла в хранилище: «0123456789abcdef.jpg».
pub fn fileName(buf: *[24]u8, hash: u64, kind: image.Kind) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}{s}", .{ hash, image.ext(kind) }) catch unreachable;
}

/// Разбор имени из адреса /img/b/ИМЯ; null — не имя хранилища.
pub fn parseName(name: []const u8) ?struct { u64, image.Kind } {
    if (name.len != 20 or name[16] != '.') return null;
    const kind: image.Kind = if (std.mem.eql(u8, name[17..], "jpg")) .jpg else if (std.mem.eql(u8, name[17..], "png")) .png else return null;
    for (name[0..16]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    return .{ std.fmt.parseInt(u64, name[0..16], 16) catch return null, kind };
}

pub const Stats = struct { new: usize = 0, cached: usize = 0, failed: usize = 0 };

/// Картинка книги → готовый файл хранилища; null — не PNG/JPEG или не разобралась.
pub fn put(gpa: std.mem.Allocator, dir: std.fs.Dir, src: fb2.SrcImage, st: *Stats) ?snapshot.InImage {
    if (src.bytes.len == 0) {
        st.failed += 1;
        return null;
    }
    const hash = hashOf(src.bytes);
    // уже обработана: вид и размер — из заголовка готового файла
    for ([_]image.Kind{ .jpg, .png }) |kind| {
        var nb: [24]u8 = undefined;
        const f = dir.openFile(fileName(&nb, hash, kind), .{}) catch continue;
        defer f.close();
        var head: [4096]u8 = undefined;
        const n = f.readAll(&head) catch continue;
        const k, const w, const h = image.info(head[0..n]) orelse continue;
        if (k != kind) continue;
        st.cached += 1;
        return .{ .hash = hash, .w = @intCast(w), .h = @intCast(h), .kind = @intFromEnum(kind), .caption = src.caption };
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = image.process(arena.allocator(), src.bytes) catch {
        st.failed += 1;
        return null;
    };
    var nb: [24]u8 = undefined;
    const name = fileName(&nb, hash, out.kind);
    // через временное имя: недописанный файл не попадёт под настоящим
    var tb: [32]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.tmp", .{name}) catch unreachable;
    dir.writeFile(.{ .sub_path = tmp, .data = out.bytes }) catch {
        st.failed += 1;
        return null;
    };
    dir.rename(tmp, name) catch {
        dir.deleteFile(tmp) catch {};
        st.failed += 1;
        return null;
    };
    st.new += 1;
    return .{ .hash = hash, .w = @intCast(out.w), .h = @intCast(out.h), .kind = @intFromEnum(out.kind), .caption = src.caption };
}

/// Убирает из хранилища файлы, на которые не ссылается ни один из снимков `keep`.
pub fn sweep(dir: std.fs.Dir, keep: []const []const snapshot.Image) void {
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".tmp")) {
            dir.deleteFile(e.name) catch {};
            continue;
        }
        const hash, const kind = parseName(e.name) orelse continue;
        const used = blk: {
            for (keep) |list| for (list) |im| if (im.hash == hash and im.kind == @intFromEnum(kind)) break :blk true;
            break :blk false;
        };
        if (!used) dir.deleteFile(e.name) catch {};
    }
}

test "имя файла хранилища туда и обратно" {
    var nb: [24]u8 = undefined;
    const name = fileName(&nb, 0x00ab_cdef_0123_4567, .png);
    try std.testing.expectEqualStrings("00abcdef01234567.png", name);
    const h, const k = parseName(name).?;
    try std.testing.expectEqual(@as(u64, 0x00ab_cdef_0123_4567), h);
    try std.testing.expectEqual(image.Kind.png, k);
    try std.testing.expect(parseName("../../etc/passwd.jpg") == null);
    try std.testing.expect(parseName("00ABCDEF01234567.png") == null);
    try std.testing.expect(parseName("00abcdef01234567.gif") == null);
}
