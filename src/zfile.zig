//! Файл словаря zstd `clipper<N>.zstd` (BACKLOG_RU.md §16): словарь обучает сам сайт
//! (`clipper zstd N …`), и лежит он рядом, а не в программе.
//!
//!   "CLIPZDIC" | версия u32 | кадр, КБ u32 | длина словаря u32 | отпечаток u32 | словарь
//!
//! Имя файла нужно только для поиска; размер кадра — из содержимого. Файл —
//! внешний ввод: всё проверяется, испорченный файл не доходит до распаковки.

const std = @import("std");

pub const magic = "CLIPZDIC".*;
pub const version: u32 = 1;
/// Кадр — от 4 до 32 КБ: страница чтения не больше 32 КБ, кадры её не пересекают.
pub const min_kb = 4;
pub const max_kb = 32;
pub const max_dict = 1 << 20;

/// Что сказано флагом -zstd.
pub const Spec = union(enum) {
    /// флага нет — deflate
    off,
    /// -zstd: словарь текущего снимка, иначе наибольший clipper<N>.zstd
    auto,
    /// -zstd N: clipper<N>.zstd
    kb: u32,
    /// -zstd ПУТЬ
    path: []const u8,
};

pub const Dict = struct {
    frame_kb: u32 = 16,
    bytes: []const u8 = "",
    hash: u32 = 0,

    pub fn frameBytes(d: Dict) usize {
        return @as(usize, d.frame_kb) * 1024;
    }
};

const Head = extern struct { magic: [8]u8, version: u32, frame_kb: u32, len: u32, hash: u32 };

pub fn kbOk(kb: u32) bool {
    return kb >= min_kb and kb <= max_kb;
}

/// Отпечаток словаря вместе с размером кадра; никогда не 0 (0 — «словаря нет»).
pub fn hashOf(frame_kb: u32, dict: []const u8) u32 {
    var h = std.hash.Wyhash.init(3);
    h.update(std.mem.asBytes(&frame_kb));
    h.update(dict);
    const v: u32 = @truncate(h.final());
    return if (v == 0) 1 else v;
}

pub fn encode(a: std.mem.Allocator, frame_kb: u32, dict: []const u8) ![]u8 {
    std.debug.assert(kbOk(frame_kb) and dict.len <= max_dict);
    const out = try a.alloc(u8, @sizeOf(Head) + dict.len);
    const h = Head{ .magic = magic, .version = version, .frame_kb = frame_kb, .len = @intCast(dict.len), .hash = hashOf(frame_kb, dict) };
    @memcpy(out[0..@sizeOf(Head)], std.mem.asBytes(&h));
    @memcpy(out[@sizeOf(Head)..], dict);
    return out;
}

/// Словарь — срез `bytes`.
pub fn decode(bytes: []const u8) error{BadDict}!Dict {
    if (bytes.len < @sizeOf(Head)) return error.BadDict;
    var h: Head = undefined;
    @memcpy(std.mem.asBytes(&h), bytes[0..@sizeOf(Head)]);
    if (!std.mem.eql(u8, &h.magic, &magic) or h.version != version or !kbOk(h.frame_kb)) return error.BadDict;
    if (h.len > max_dict or h.len != bytes.len - @sizeOf(Head)) return error.BadDict;
    const dict = bytes[@sizeOf(Head)..];
    if (h.hash != hashOf(h.frame_kb, dict)) return error.BadDict;
    return .{ .frame_kb = h.frame_kb, .bytes = dict, .hash = h.hash };
}

pub fn fileName(buf: *[32]u8, kb: u32) []const u8 {
    return std.fmt.bufPrint(buf, "clipper{d}.zstd", .{kb}) catch unreachable;
}

/// N из имени clipper<N>.zstd.
fn kbOfName(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "clipper") or !std.mem.endsWith(u8, name, ".zstd")) return null;
    const n = std.fmt.parseInt(u32, name["clipper".len .. name.len - ".zstd".len], 10) catch return null;
    return if (kbOk(n)) n else null;
}

/// Загруженный словарь: `mem` — весь файл (освобождает вызывающий), `dict` — срез его.
pub const Loaded = struct {
    mem: []u8,
    dict: Dict,
    /// где найден — для сообщений
    path: []const u8,

    pub fn deinit(l: Loaded, gpa: std.mem.Allocator) void {
        gpa.free(l.path);
        gpa.free(l.mem);
    }
};

pub const Error = error{ NoDict, BadDict, OutOfMemory };

/// Какой файл не нашёлся или испорчен — для сообщения об ошибке.
pub var problem: []const u8 = "";

fn loadAt(gpa: std.mem.Allocator, dir: std.fs.Dir, dir_path: []const u8, name: []const u8) Error!?Loaded {
    const mem = dir.readFileAlloc(gpa, name, max_dict + @sizeOf(Head)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadDict,
    };
    errdefer gpa.free(mem);
    const d = try decode(mem);
    const path = if (dir_path.len == 0) try gpa.dupe(u8, name) else try std.fs.path.join(gpa, &.{ dir_path, name });
    return .{ .mem = mem, .dict = d, .path = path };
}

/// Ищет словарь по флагу: `clipper<N>.zstd` — в текущей папке, затем в папке
/// программы; без N — тот, чей отпечаток `want` (словарь текущего снимка), иначе
/// с наибольшим N. Нет словаря — error.NoDict, испорчен — error.BadDict; `bad`
/// получает путь к испорченному файлу.
pub fn resolve(gpa: std.mem.Allocator, spec: Spec, want: u32, bad: *[]const u8) Error!Loaded {
    switch (spec) {
        .off => return error.NoDict,
        .path => |p| {
            bad.* = p;
            return (try loadAt(gpa, std.fs.cwd(), "", p)) orelse error.NoDict;
        },
        else => {},
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_buf) catch "";
    const places = [_][]const u8{ "", exe_dir };
    if (spec == .kb) {
        var nb: [32]u8 = undefined;
        const name = fileName(&nb, spec.kb);
        for (places, 0..) |place, k| {
            if (k == 1 and place.len == 0) continue;
            var dir = if (place.len == 0) std.fs.cwd() else std.fs.openDirAbsolute(place, .{}) catch continue;
            defer if (place.len != 0) dir.close();
            bad.* = name;
            if (try loadAt(gpa, dir, place, name)) |l| return l;
        }
        return error.NoDict;
    }
    // -zstd без числа: словарь снимка, иначе наибольший
    var best: ?Loaded = null;
    errdefer if (best) |b| b.deinit(gpa);
    for (places, 0..) |place, k| {
        if (k == 1 and (place.len == 0 or samePlace(place))) continue;
        var dir = (if (place.len == 0) std.fs.cwd().openDir(".", .{ .iterate = true }) else std.fs.openDirAbsolute(place, .{ .iterate = true })) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .file) continue;
            _ = kbOfName(e.name) orelse continue;
            const l = (loadAt(gpa, dir, place, e.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue, // испорченный файл при поиске пропускается
            }) orelse continue;
            if (want != 0 and l.dict.hash == want) {
                if (best) |b| b.deinit(gpa);
                best = null;
                return l;
            }
            // наибольший — по содержимому (размер кадра в файле), первый найденный при равенстве
            if (best == null or l.dict.frame_kb > best.?.dict.frame_kb) {
                if (best) |b| b.deinit(gpa);
                best = l;
            } else l.deinit(gpa);
        }
    }
    return best orelse error.NoDict;
}

/// Папка программы — это текущая папка: второй раз её не перебирать.
fn samePlace(exe_dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch return false;
    return std.mem.eql(u8, cwd, exe_dir);
}

test "файл словаря: туда и обратно, порча не проходит" {
    const a = std.testing.allocator;
    const dict = "словарь словарь словарь";
    const f = try encode(a, 32, dict);
    defer a.free(f);
    const d = try decode(f);
    try std.testing.expectEqual(@as(u32, 32), d.frame_kb);
    try std.testing.expectEqualStrings(dict, d.bytes);
    try std.testing.expectEqual(hashOf(32, dict), d.hash);
    // другой размер кадра — другой отпечаток
    try std.testing.expect(hashOf(16, dict) != hashOf(32, dict));
    // любой испорченный байт и любая обрезка — ошибка
    const bad = try a.dupe(u8, f);
    defer a.free(bad);
    for (0..bad.len) |i| {
        bad[i] ^= 0x41;
        try std.testing.expectError(error.BadDict, decode(bad));
        bad[i] ^= 0x41;
    }
    for (0..f.len) |n| try std.testing.expectError(error.BadDict, decode(f[0..n]));
    try std.testing.expectEqual(@as(?u32, 16), kbOfName("clipper16.zstd"));
    try std.testing.expectEqual(@as(?u32, null), kbOfName("clipper64.zstd"));
    try std.testing.expectEqual(@as(?u32, null), kbOfName("clipperx.zstd"));
}
