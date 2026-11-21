//! Несколько процессов-воркеров на одном слушающем сокете (`-w N`).
//!
//! Главный процесс открывает сокет и запускает N воркеров; сам запросов не
//! обслуживает, а ждёт: упавшего воркера запускает заново. Каждый воркер —
//! обычный однопоточный сервер со своим циклом событий; соединение достаётся
//! тому, кто первым позвал `accept`. Данные общие — через файл хранилища
//! (ledger.zig: `hold`, `refresh`) и файлы снимка каталога.
//!
//!   Linux     `fork`: воркер наследует сокет и продолжает с того же места
//!   Windows   `CreateProcessW` с наследованием дескрипторов и той же командной
//!             строкой плюс `--worker СОКЕТ:ГЛАВНЫЙ:НОМЕР:ШЛЮЗ`. `SO_REUSEPORT` в
//!             Windows нет, а наследование сокета есть начиная с XP.
//!             Принимает соединения тот воркер, кто держит шлюз (net.Gate).
//!
//! Воркер раз в секунду проверяет, жив ли главный, и выходит вслед за ним.

const std = @import("std");
const t9n = @import("t9n.zig");
const builtin = @import("builtin");
const net = @import("net/net.zig");
const sys = @import("sys.zig");

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const linux = std.os.linux;

pub const max_workers = 64; // предел WaitForMultipleObjects

const w32 = struct {
    extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
    extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn WaitForSingleObject(h: windows.HANDLE, ms: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn WaitForMultipleObjects(n: windows.DWORD, handles: [*]const windows.HANDLE, all: windows.BOOL, ms: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn SetHandleInformation(h: windows.HANDLE, mask: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetModuleFileNameW(module: ?windows.HMODULE, buf: [*]u16, len: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CloseHandle(h: windows.HANDLE) callconv(.winapi) windows.BOOL;
    const synchronize: windows.DWORD = 0x00100000;
    const handle_flag_inherit: windows.DWORD = 1;
    const infinite: windows.DWORD = 0xFFFFFFFF;
};

/// Кто этот процесс после запуска воркеров.
pub const Worker = struct {
    /// Номер с единицы.
    index: u32,
    lfd: net.Socket,
    parent: Parent,
    /// Шлюз приёма соединений (Windows); на Linux не нужен.
    gate: ?net.Gate = null,
};

pub const Parent = if (is_windows) windows.HANDLE else linux.pid_t;

/// true — главный процесс завершился: воркеру пора выходить.
pub fn orphaned(p: Parent) bool {
    if (is_windows) return w32.WaitForSingleObject(p, 0) == 0;
    return linux.getppid() != p;
}

/// Разбирает `--worker СОКЕТ:ГЛАВНЫЙ:НОМЕР:ШЛЮЗ` (только Windows).
pub fn fromSpec(spec: []const u8) ?Worker {
    if (!is_windows) return null;
    var it = std.mem.splitScalar(u8, spec, ':');
    const sock = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const pid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const index = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const gate = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or index == 0 or index > max_workers or sock == 0 or gate == 0) return null;
    const parent = w32.OpenProcess(w32.synchronize, windows.FALSE, pid) orelse return null;
    return .{ .index = index, .lfd = @ptrFromInt(sock), .parent = parent, .gate = @ptrFromInt(gate) };
}

/// Запускает `n` воркеров на сокете `lfd` и следит за ними. На Windows не
/// возвращается; на Linux возвращается в каждом воркере.
pub fn supervise(gpa: std.mem.Allocator, lfd: net.Socket, n: u32) Worker {
    std.debug.assert(n >= 1 and n <= max_workers);
    if (is_windows) superviseWindows(gpa, lfd, n);
    return superviseLinux(lfd, n);
}

fn superviseLinux(lfd: net.Socket, n: u32) Worker {
    if (is_windows) unreachable;
    const me = linux.getpid();
    var pids = [_]linux.pid_t{0} ** max_workers;
    var quick_deaths: u32 = 0;
    while (true) {
        for (pids[0..n], 0..) |*pid, i| {
            if (pid.* != 0) continue;
            const child = std.posix.fork() catch |err| {
                std.debug.print(t9n.tr("[clipper] воркер {d} не запущен: {s}\n"), .{ i + 1, @errorName(err) });
                continue;
            };
            if (child == 0) return .{ .index = @intCast(i + 1), .lfd = lfd, .parent = me };
            pid.* = child;
        }
        const started = sys.now();
        const dead = std.posix.waitpid(-1, 0);
        for (pids[0..n], 0..) |*pid, i| if (pid.* == dead.pid) {
            pid.* = 0;
            std.debug.print(t9n.tr("[clipper] воркер {d} завершился (состояние {d}), запускаю заново\n"), .{ i + 1, dead.status });
        };
        pause(started, &quick_deaths);
    }
}

/// Воркеры, которые падают сразу после запуска, не должны крутить процессор.
fn pause(started: i64, quick_deaths: *u32) void {
    if (sys.now() - started >= 5) {
        quick_deaths.* = 0;
        return;
    }
    quick_deaths.* += 1;
    if (quick_deaths.* >= 20) {
        std.debug.print(t9n.tr("clipper: воркеры завершаются сразу после запуска, останавливаюсь\n"), .{});
        std.process.exit(1);
    }
    sys.sleepMs(1000);
}

fn superviseWindows(gpa: std.mem.Allocator, lfd: net.Socket, n: u32) noreturn {
    if (!is_windows) unreachable;
    // Сокет наследуется по умолчанию, но флаг мог снять тот, кто нас запустил.
    _ = w32.SetHandleInformation(@ptrCast(lfd), w32.handle_flag_inherit, w32.handle_flag_inherit);
    var exe: [1024]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len - 1) fatal(t9n.tr("путь к clipper.exe не получен"));
    exe[exe_len] = 0;
    const base = std.mem.span(w32.GetCommandLineW());
    const gate = net.gateCreate() orelse fatal(t9n.tr("шлюз приёма соединений не создан"));

    var handles: [max_workers]windows.HANDLE = undefined;
    var alive = [_]bool{false} ** max_workers;
    var quick_deaths: u32 = 0;
    while (true) {
        for (0..n) |i| {
            if (alive[i]) continue;
            handles[i] = spawn(gpa, exe[0..exe_len :0], base, lfd, gate, @intCast(i + 1)) orelse {
                std.debug.print(t9n.tr("[clipper] воркер {d} не запущен: ошибка Windows {d}\n"), .{ i + 1, @intFromEnum(windows.GetLastError()) });
                continue;
            };
            alive[i] = true;
        }
        // ждать можно только сплошной массив: живые — в начало
        var wait: [max_workers]windows.HANDLE = undefined;
        var who: [max_workers]usize = undefined;
        var count: u32 = 0;
        for (0..n) |i| if (alive[i]) {
            wait[count] = handles[i];
            who[count] = i;
            count += 1;
        };
        if (count == 0) fatal(t9n.tr("ни один воркер не запустился"));
        const started = sys.now();
        const r = w32.WaitForMultipleObjects(count, &wait, windows.FALSE, w32.infinite);
        if (r >= count) fatal(t9n.tr("ожидание воркеров прервано"));
        const i = who[r];
        _ = w32.CloseHandle(handles[i]);
        alive[i] = false;
        std.debug.print(t9n.tr("[clipper] воркер {d} завершился, запускаю заново\n"), .{i + 1});
        pause(started, &quick_deaths);
    }
}

fn spawn(gpa: std.mem.Allocator, exe: [:0]const u16, base: []const u16, lfd: net.Socket, gate: net.Gate, index: u32) ?windows.HANDLE {
    if (!is_windows) unreachable;
    var tail_buf: [96]u8 = undefined;
    const tail = std.fmt.bufPrint(&tail_buf, " --worker {d}:{d}:{d}:{d}", .{ @intFromPtr(lfd), w32.GetCurrentProcessId(), index, @intFromPtr(gate) }) catch unreachable;
    // CreateProcessW вправе менять строку: ей нужна своя копия
    const cmd = gpa.allocSentinel(u16, base.len + tail.len, 0) catch return null;
    defer gpa.free(cmd);
    @memcpy(cmd[0..base.len], base);
    for (tail, cmd[base.len..]) |ch, *o| o.* = ch;

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(exe.ptr, cmd.ptr, null, null, windows.TRUE, 0, null, null, &si, &pi) == 0) return null;
    _ = w32.CloseHandle(pi.hThread);
    return pi.hProcess;
}

fn fatal(comptime what: []const u8) noreturn {
    std.debug.print("clipper: " ++ t9n.tr(what) ++ "\n", .{});
    std.process.exit(1);
}
