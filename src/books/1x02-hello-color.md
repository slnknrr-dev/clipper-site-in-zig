## Colored output and the Windows console

Colored output is a good occasion to talk about how a terminal is not a "screen" but a program at the other end of a byte stream, and how Windows differs from other systems more than it seems.

### Escape sequences

Color in a terminal is set not by calling a function but by bytes in the same stream as the text. A sequence starts with the ESC character (code 27, `\x1b`), then `[`, numbers and a letter:

```
const std = @import("std");

const red = "\x1b[31m";
const green = "\x1b[32m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("{s}{s}error:{s} file not found\n", .{ bold, red, reset });
    try out.print("{s}done{s}\n", .{ green, reset });
}
```

`31` is red text, `32` green, `1` bold, `0` reset. This is the ECMA-48 standard, older than most readers of this book.

### Question: what if the output is not a terminal?

If output is redirected to a file (`program > log.txt`), the file will contain the bytes `\x1b[31m`. A good program checks where it is writing:

```
const std = @import("std");

pub fn main() !void {
    const file = std.io.getStdOut();
    const tty = std.io.tty.detectConfig(file);
    const out = file.writer();
    try tty.setColor(out, .red);
    try out.writeAll("error");
    try tty.setColor(out, .reset);
    try out.writeAll("\n");
}
```

`detectConfig` checks whether it is a terminal and takes into account the `NO_COLOR` environment variable and the system. On Windows it can also use the old way — console calls — if escape sequences are not supported.

### Windows: two problems, not one

**Encoding.** By default the Windows console expects bytes in its own code page (866 or 1251 on a Russian system), not UTF-8. Zig strings are UTF-8, and without setup Cyrillic comes out as garbage. Clipper switches the console at the start of `main`:

```
extern "kernel32" fn SetConsoleOutputCP(cp: c_uint) callconv(.winapi) c_int;

pub fn main() void {
    if (builtin.os.tag == .windows) _ = SetConsoleOutputCP(65001);
    ...
}
```

65001 is the number of UTF-8. Note how the function is declared: `extern "kernel32"` — right in the code, without headers and without a C library. The compiler itself knows how to call a function from a system library. This is one of the reasons Zig is convenient for building for Windows without foreign code.

**Escape sequences.** The Windows console understands them only from Windows 10, and even then only after the `ENABLE_VIRTUAL_TERMINAL_PROCESSING` mode is explicitly enabled with `SetConsoleMode`. Windows XP and 7 do not have them at all: `\x1b[31m` will be printed as is. That is why Clipper's server does not write color to the console: its target is XP, and "works everywhere" matters more here than beauty.

### What this example teaches

Colored output looks like decoration, but behind it are three questions that come up in any systems program: what is at the other end of the stream, what encoding it expects, and which system versions must be supported. Zig hides none of them, and rightly so: a language that offered "just a colored print" would decide for you what to do on XP.
