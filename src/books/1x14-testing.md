## Tests

### Tests next to the code

```
fn add(a: u32, b: u32) u32 {
    return a + b;
}

test "addition" {
    try std.testing.expectEqual(@as(u32, 5), add(2, 3));
}
```

A test is a block in the same file as the code. `zig test file.zig` builds and runs all of a file's tests; an ordinary build does not contain them. The name is a string, in any language.

Why next to the code: a test is an example of use, and its place is next to what it demonstrates. And a test sees the file's private functions.

### A trap: tests that never run

A file's tests get into the run only if the file is "reachable" from the root. Importing a file does not make its tests reachable if nothing refers to them. That is why Clipper has `src/lib.zig`, whose only job is to list all modules:

```
test {
    inline for (.{ cp1251, out, http, journal, btree, ... }) |m| _ = m;
}
```

Forget to add a module to this list and you get tests that never run and always "pass". This is a real trap in the language, and it is worth knowing about in advance.

### An allocator that counts

`std.testing.allocator` remembers every allocation. If something is not freed by the end of the test, the test fails and shows where it was allocated. If something is freed twice — likewise. Every test that works with memory is also a leak test.

### Random input with a constant seed

```
var prng = std.Random.DefaultPrng.init(42);
const rnd = prng.random();
```

A generator with a constant seed produces the same sequence on every run. A failed case repeats and can be debugged. A random test that fails once a week and does not repeat is worse than no test: it teaches you not to trust red.

### Test build mode

Clipper's tests are built in Debug — with all checks. Bounds and overflow checks turn any parser bug into an immediate stop with an address. Without these checks the hostile-input tests would catch only crashes; with them, silent out-of-bounds accesses too.

### What Zig tests cannot do

No built-in mocks, fixtures or parameterized tests. Only the `test` block and assertion functions. Everything else is ordinary code. That is consistent: the language does not add a mechanism if it can be written as a function.
