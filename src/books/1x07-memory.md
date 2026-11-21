## Memory: the allocator is a parameter

### Question: why is there no `malloc`?

Zig has no global default allocator. A function that needs memory gets an allocator as a parameter:

```
fn join(a: std.mem.Allocator, x: []const u8, y: []const u8) ![]u8 {
    const out = try a.alloc(u8, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}
```

This is inconvenient for exactly one day. Then it turns out that the signature shows whether a function allocates memory or not. A function without an `Allocator` parameter does not allocate — a guarantee you can check by reading. For a server whose main property is "nothing is allocated on the request path", this is a way to check the property without a profiler.

`std.mem.Allocator` is an interface: a pointer to state and a table of functions. Any allocator can be passed to any function.

### Standard library allocators

| allocator | when |
| std.heap.page_allocator | straight from the system, in pages; slow but stateless |
| std.heap.ArenaAllocator | many allocations, all freed at once |
| std.heap.FixedBufferAllocator | sequential allocations from a ready buffer; no system calls |
| std.heap.DebugAllocator | catches leaks, double frees, use after free (renamed from GeneralPurposeAllocator in 0.14) |
| std.heap.smp_allocator | a fast general-purpose allocator for multithreaded programs (new in 0.14) |
| std.testing.allocator | in tests: fails the test on a leak |

### How the server uses it

At startup Clipper allocates three buffers: the request arena (24 MB), the page body (6 MB), the finished response (8 MB). For each request an allocator is created on top of the first:

```
var fba = std.heap.FixedBufferAllocator.init(app.arena_buf);
const a = fba.allocator();
```

Creating it means writing two numbers. Individual pieces need not be freed: the request ended — the allocator is forgotten, and the next one starts at the beginning of the buffer. Forgetting to free is impossible because there is nothing to free; freeing twice — for the same reason.

### Question: who owns the result?

This is the main question for a language without a garbage collector, and Zig answers it with a convention visible in the signature. If a function takes an allocator and returns a slice, the result belongs to the caller and lives as long as the allocator's memory. Clipper's record store returns a copy of the value precisely for this reason:

```
pub fn get(l: *Ledger, a: std.mem.Allocator, k: []const u8) ?[]const u8
```

If it returned a slice into its own memory, the next write of the same key would overwrite it under the reader's feet. In Rust the borrow checker would not let such a bug compile. In Zig only the convention protects against it — and tests.

### The testing allocator

```
test "no leaks" {
    const a = std.testing.allocator;
    const s = try join(a, "ab", "cd");
    defer a.free(s);
    try std.testing.expectEqualStrings("abcd", s);
}
```

Remove `defer a.free(s)` and the test fails and shows where the unfreed memory was allocated. A leak stops being something noticed a month later on a memory graph.

### Price

Use of freed memory is caught by nothing in ReleaseSafe. `DebugAllocator` catches it in debug but not in a production build. This is the biggest hole in Zig's safety compared to Rust, and it is closed by program design, not by the language: request memory lives until the end of the request and is freed all at once, so there is almost nowhere to write "freed too early".

A fixed buffer is a ceiling. A request that needs more than 24 MB will not complete. This is a limitation, not protection, and its size was chosen for the heaviest operation — parsing an uploaded book.
