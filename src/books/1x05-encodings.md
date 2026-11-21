## Encodings: bytes versus text

### Question: what is a string's length?

```
const std = @import("std");

pub fn main() !void {
    const s = "Ёлка"; // "fir tree" in Russian
    std.debug.print("bytes: {d}\n", .{s.len});                              // 8
    std.debug.print("chars: {d}\n", .{try std.unicode.utf8CountCodepoints(s)}); // 4
}
```

Zig sources are UTF-8, and a literal is stored in UTF-8. A Cyrillic letter is two bytes. `s.len` is the number of bytes, and there is no other "built-in" notion of length. How many characters a string has is decided by a function, and it may return an error: the bytes are not required to be valid UTF-8.

This follows directly from a string in Zig being bytes. The language does not pretend to know what is in them.

### Iterating by character

```
var it = (try std.unicode.Utf8View.init("Ёлка")).iterator();
while (it.nextCodepoint()) |cp| std.debug.print("U+{X:0>4}\n", .{cp});
```

`Utf8View.init` checks the whole string once; after that iteration runs without checks. A common Zig technique: check at the boundary, trust afterwards.

### Single-byte encodings

Clipper stores and serves text in windows-1251: one byte, one letter. Conversion from UTF-8 is its own function in `src/cp1251.zig`: for each character, find a byte in a 64-entry table or, if the character is not in the encoding, write `&#N;`.

Why not the standard library: it has UTF-8, UTF-16 and ASCII but no single-byte encodings. And rightly so: code page tables are data, not part of the language.

### Re-encoding at compile time

The most interesting part is where this function is called. Interface strings are written in the sources in Russian in UTF-8, and they reach the page in windows-1251. The re-encoding happens at compile time:

```
pub fn lit(comptime utf8: []const u8) []const u8 {
    return &Converted(utf8, true).v;
}
```

`comptime utf8` — the argument must be known at compile time. `Converted` calls the very same `encode` that runs at run time, but the compiler executes it itself and puts ready bytes into the program. In the running server there is no re-encoding of interface strings at all. How this works — the chapter on `comptime`.

### Where the boundary lies

Clipper's rule: one encoding inside, re-encoding at the boundaries. Book files arrive in UTF-8 and are re-encoded on parsing. Exports (txt, fb2, epub) and JSON go out in UTF-8. An address typed by hand arrives in UTF-8, and the server recognizes it (`looksUtf8`).

The price of a single-byte encoding is the languages outside it. Georgian text does not fit in windows-1251, and it had to be removed from Clipper's build. The Zig language has nothing to do with it: it is equally indifferent to any encoding. The program makes the decision.
