//! То, что у Linux и Windows разное и чего нет в std для Windows XP:
//! часы, местное время, отображение файла в память, блокировка файла.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;

pub const is_windows = builtin.os.tag == .windows;

const w32 = struct {
    const SYSTEMTIME = extern struct { year: u16, month: u16, wday: u16, day: u16, hour: u16, min: u16, sec: u16, ms: u16 };
    extern "kernel32" fn GetSystemTimeAsFileTime(time: *windows.FILETIME) callconv(.winapi) void;
    extern "kernel32" fn GetLocalTime(time: *SYSTEMTIME) callconv(.winapi) void;
    extern "kernel32" fn CreateFileMappingW(file: windows.HANDLE, attributes: ?*anyopaque, protect: windows.DWORD, size_high: windows.DWORD, size_low: windows.DWORD, name: ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: windows.DWORD, offset_high: windows.DWORD, offset_low: windows.DWORD, bytes: usize) callconv(.winapi) ?[*]align(std.heap.page_size_min) u8;
    extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(ms: windows.DWORD) callconv(.winapi) void;
};

/// Миллисекунды с 1970 года. `std.time` на Windows зовёт RtlGetSystemTimePrecise,
/// которой нет до Windows 8.
pub fn nowMs() i64 {
    if (is_windows) {
        var ft: windows.FILETIME = undefined;
        w32.GetSystemTimeAsFileTime(&ft);
        const ticks = (@as(i64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime; // по 100 нс с 1601 года
        return @divFloor(ticks, 10_000) - 11_644_473_600_000;
    }
    return std.time.milliTimestamp();
}

pub fn now() i64 {
    return @divFloor(nowMs(), 1000);
}

/// Час по местному времени сервера (на Linux без libc — по UTC).
pub fn localHour() u8 {
    if (is_windows) {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        return @intCast(st.hour);
    }
    return @intCast(@mod(@divFloor(now(), 3600), 24));
}

pub fn sleepMs(ms: u32) void {
    if (is_windows) w32.Sleep(ms) else std.time.sleep(@as(u64, ms) * std.time.ns_per_ms);
}

pub fn random(buf: []u8) void {
    std.crypto.random.bytes(buf);
}

/// Файл, отображённый в память только для чтения.
pub const Mapping = struct {
    bytes: []align(std.heap.page_size_min) const u8,
    handle: if (is_windows) windows.HANDLE else void,

    pub fn open(dir: std.fs.Dir, name: []const u8) !Mapping {
        const file = try dir.openFile(name, .{});
        defer file.close();
        const len: usize = @intCast(try file.getEndPos());
        if (len == 0) return error.EmptyFile;
        if (is_windows) {
            const h = w32.CreateFileMappingW(file.handle, null, 0x02, 0, 0, null) orelse return error.MapFailed;
            const p = w32.MapViewOfFile(h, 0x04, 0, 0, 0) orelse {
                windows.CloseHandle(h);
                return error.MapFailed;
            };
            return .{ .bytes = p[0..len], .handle = h };
        }
        const m = try posix.mmap(null, len, posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0);
        return .{ .bytes = m, .handle = {} };
    }

    pub fn close(m: *Mapping) void {
        if (is_windows) {
            _ = w32.UnmapViewOfFile(m.bytes.ptr);
            windows.CloseHandle(m.handle);
        } else posix.munmap(m.bytes);
        m.bytes = m.bytes[0..0];
    }
};

// Блокировки Windows обязательные: запертый байт никто не прочтёт. Поэтому
// запирается один байт далеко за концом файла. На Linux — flock.
const lock_offset: windows.LARGE_INTEGER = 1 << 62;
const lock_length: windows.LARGE_INTEGER = 1;

fn tryLock(file: std.fs.File) !bool {
    if (is_windows) {
        var io: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(file.handle, null, null, null, &io, &lock_offset, &lock_length, null, windows.TRUE, windows.TRUE) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        return true;
    }
    posix.flock(file.handle, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |e| return e,
    };
    return true;
}

/// Исключительная блокировка файла; ждёт до 10 секунд.
pub fn lock(file: std.fs.File) !void {
    var waited: u32 = 0;
    while (!(try tryLock(file))) {
        if (waited >= 10_000) return error.Busy;
        // первые полсекунды — частые попытки: так ждут друг друга воркеры
        const step: u32 = if (waited < 500) 1 else 20;
        sleepMs(step);
        waited += step;
    }
}

pub fn unlock(file: std.fs.File) void {
    if (is_windows) {
        var io: windows.IO_STATUS_BLOCK = undefined;
        windows.UnlockFile(file.handle, &io, &lock_offset, &lock_length, null) catch {};
    } else posix.flock(file.handle, posix.LOCK.UN) catch {};
}

test "часы" {
    const t = now();
    try std.testing.expect(t > 1_700_000_000 and t < 4_000_000_000);
    try std.testing.expect(localHour() < 24);
}
