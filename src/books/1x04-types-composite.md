## Arrays, slices, pointers and structs

### Five kinds of pointer

In C there is one pointer, and from the type `char *` you cannot tell what it points to: one character, an array, a zero-terminated string. In Zig these are different types.

| type | what it is |
| *T | a pointer to one value |
| [*]T | a pointer to an unknown number of values (as in C) |
| []T | a slice: a pointer and a length |
| [*:0]T | a pointer to a sequence ending in zero |
| [:0]T | a slice guaranteed to be followed by a zero |
| ?*T | a pointer that may be null |

An ordinary pointer `*T` cannot be null. For it to be able to, the type is written `?*T`, and it must be checked before use. A whole class of bugs removed by a type.

### The slice is the main type in server code

A slice is a "pointer, length" pair. It does not own memory; it points at it. Almost all of Clipper works with slices: request parsing returns slices into the socket buffer, a book lookup returns a slice into the mapped file, a page is written in slices.

```
const std = @import("std");

pub fn main() void {
    const req = "GET /b/42 HTTP/1.1";
    const sp = std.mem.indexOfScalar(u8, req, ' ').?;
    const path = req[sp + 1 .. sp + 6];
    std.debug.print("{s}\n", .{path}); // /b/42
}
```

`path` is not a copy but a window into `req`. In a debug build going past a slice's bounds is a stop. The price: a slice lives no longer than the memory it points to, and the language does not track that. More on this in the chapter on memory.

### Question: what is a string literal?

The type of `"Hello"` is `*const [5:0]u8`: a pointer to an array of five bytes followed by a zero. It coerces implicitly to `[]const u8` (a slice) and to `[*:0]const u8` (a C string). Zig has no separate "string" type. A string is bytes.

Why: because a "string" in every language is a decision about encoding, memory ownership and immutability made for you. Zig refuses to make it for you. In Clipper this is especially visible: strings inside the server are in windows-1251, not UTF-8, and the type `[]const u8` does not get in the way at all.

### Optionals and unions

`?T` is a value or `null`. It is unwrapped with `if (x) |v|`, `orelse` or `.?` (the last means "I am sure it is not null", checked in Debug).

`union(enum)` is a tagged union: a value of one of the variants plus a tag saying which. A `switch` on it must handle every variant. Clipper's record store is built this way: `union(Kind) { journal: Journal, btree: Tree }`. Add a third variant and the compiler shows every place where it was forgotten.

### Structs and memory layout

In an ordinary `struct` the order of fields in memory is not defined: the compiler may reorder them for alignment. That is good for memory and bad for files. For data that lies in a file or is passed to the system there are two other kinds:

- `extern struct` — C layout rules: fields in order, predictable alignment. Clipper puts such structs into the snapshot file and reads them straight from mapped memory.
- `packed struct` — fields packed tightly, bit by bit; handy for flags and network headers.

```
const Page = extern struct {
    first_frame: u32,
    n_frames: u32,
    len: u32,
};
comptime {
    std.debug.assert(@sizeOf(Page) == 12);
}
```

The last three lines are a compile-time check. If someone adds a field and changes the size, the program does not build. The builtins `@sizeOf`, `@offsetOf` and `@alignOf` turn layout from a guess into an assertion.

### Price

Five kinds of pointer must be learned, and for the first weeks coercing a slice to a C string pointer feels like bureaucracy. In return the type says what lies at the address — in C you find that out by reading the caller's code.
