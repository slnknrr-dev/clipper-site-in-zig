## Files, memory mapping, locks

### Files and directories

```
const std = @import("std");

pub fn main() !void {
    var dir = try std.fs.cwd().makeOpenPath("data", .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello\n" });
    var buf: [64]u8 = undefined;
    const got = try dir.readFile("hello.txt", &buf);
    std.debug.print("{s}", .{got});
}
```

Everything goes through a directory (`Dir`): open a directory, then open files relative to it. This is not a whim. Paths relative to an open directory are safer (the directory cannot be swapped between the check and the open) and are the same on all systems. In Clipper the whole library folder is opened once at startup, and from then on the server works only inside it.

`readFile` into a ready buffer does not allocate; `readFileAlloc(a, path, limit)` does, and the limit is mandatory — a file cannot eat all the memory.

### Atomic file replacement

Writing a new file in full so that a crash does not leave it half-written is a classic problem. The solution: write to a temporary file and rename. Clipper switches the catalog snapshot like this:

```
try root.writeFile(.{ .sub_path = "library.current.tmp", .data = file_name });
try root.rename("library.current.tmp", "library.current");
```

A rename within one directory is atomic on both Linux and Windows: a reader sees either the old pointer or the new one.

### Memory mapping

Mapping (`mmap` on Linux, `CreateFileMapping` and `MapViewOfFile` on Windows) makes a file part of the address space: reading memory is reading the file, and the system pages it in by itself. For an immutable file this is the best way to read: no copying into a buffer, no cache in the program, several processes share one physical memory.

The standard library has `std.posix.mmap`, but no mapping for Windows. Clipper writes it in `src/sys.zig` — twenty lines with `extern "kernel32"` declarations. A typical situation: Zig's standard library is POSIX-oriented, and for Windows some system things have to be declared by hand. The language makes this easy: declaring a function from a system library is one line.

Mapped memory is foreign bytes. The file may have been corrupted. The rule: on opening, check all offsets and lengths that will be used as indexes — and trust afterwards. Checking on every access is more honest, but then reading stops being free.

### File locking

Several processes write to one journal. A lock visible to all processes is needed. In Zig 0.14 `File` has `lock`, but Clipper uses its own in `src/sys.zig`: `flock` on Linux, `LockFileEx` on Windows. The reason is XP: you need to know exactly which system functions are called.

A file lock is the only synchronization primitive a multi-process server needs. No in-memory mutexes, no atomic variables: processes communicate through a file and a lock on it.

### Price

System differences do not go away: they have to be gathered in one file and checked on every system. In Clipper that file is `src/sys.zig`, and it is one of the few places that will have to be rewritten on moving to a new Zig version.
