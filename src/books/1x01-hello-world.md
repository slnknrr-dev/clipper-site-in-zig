# Part I. The first bytes

## A proper Hello, World

In most textbooks "Hello, World" is one line that teaches nothing. In Zig it teaches three things at once, and all three will be needed on a server.

```
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, {s}!\n", .{"World"});
}
```

### Question 1. Where does `std` come from?

`@import("std")` returns a value — a struct holding the whole standard library. Not a preprocessor directive, not a header inclusion, but an expression. In Zig a file is a struct, and an import is obtaining that struct. So `std.io` is just a field.

The consequence: there is no "global namespace". Everything you use is visible through a chain of fields from an import. This will matter more than once.

### Question 2. Why `!void` and not `void`?

Writing to standard output can fail: the output is closed, the disk is full, the pipe is broken. In most languages `print` swallows such an error or throws an exception nobody knows about. In Zig `print` returns a possible error, and it cannot be silently ignored: either `try` (pass it up) or `catch` (handle it). `!void` on `main` means "main may return an error" — then the program exits with a non-zero code and prints the error's name.

### Question 3. What is `.{"World"}`?

An anonymous tuple. The format and arguments are checked at compile time: `{s}` requires a string, and if you pass a number the program does not build. The format string is not parsed at run time at all — the compiler turns it into a sequence of calls. This is the first example of what Zig calls `comptime`; it has a chapter of its own.

### stdout and stderr

```
std.debug.print("debug: {d}\n", .{42});
```

`std.debug.print` writes to stderr and ignores write errors. It is for debugging and failure messages, not for data. Clipper's server prints a startup line and error messages to stderr, and to stdout only what may be redirected to a file (for example, a password hash from `clipper hash`).

The distinction is not a formality: if a program writes both data and messages to one stream, its output cannot be processed by another program.

### Buffering

Every `stdout.print` call is a write system call. For one line it does not matter; for a million it decides everything.

```
const std = @import("std");

pub fn main() !void {
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();
    for (0..1000) |i| try w.print("{d}\n", .{i});
    try bw.flush();
}
```

The buffer is an ordinary stack variable: 4 KB inside the `bw` struct. No memory allocation. But you have to call `flush` yourself: Zig does nothing behind your back, including flushing the buffer on exit. Forget `flush` and you lose the end of the output.

This is the first example of a principle running through the whole language: **no hidden behaviour.** The price is more lines. The gain is that you can see where writing happens.

### What changed in 0.15

In 0.15 all of the standard library's I/O was rewritten: the buffer moved inside the writer interface, and `bufferedWriter` and `getStdOut().writer()` gave way to new calls. The code in this chapter will not build on 0.15 without edits. Why that happened and why it is a strategy rather than a mistake — in the chapter on forced decisions.
