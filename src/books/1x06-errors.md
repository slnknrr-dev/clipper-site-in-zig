# Part II. Three pillars

## Errors as values

### Question: why are there no exceptions?

An exception is hidden control flow. In a language with exceptions the line `parse(x)` may leave the function in the middle, and the text does not show it. For a server holding open files, locks and buffers, every such invisible exit point is a place for a leak or an unreleased lock.

Zig chooses differently: an error is a value returned along with the result, and every point where an error can interrupt a function is marked with the word `try`.

### Error sets

```
const ParseError = error{ Empty, NotNumber, TooBig };

fn port(s: []const u8) ParseError!u16 {
    if (s.len == 0) return error.Empty;
    const n = std.fmt.parseInt(u32, s, 10) catch return error.NotNumber;
    if (n == 0 or n > 65535) return error.TooBig;
    return @intCast(n);
}
```

`ParseError!u16` is "either one of three errors or a number". An error set is a type, and the compiler knows it in full. If you write `!u16` without a set, the compiler infers it from the function body.

The caller chooses:

- `try port(s)` — pass the error up;
- `port(s) catch 8080` — a default value;
- `port(s) catch |e| switch (e) { ... }` — handle each one; the `switch` must cover every member of the set.

The last item is the main difference from C return codes: you cannot forget a case. Add a new error to the function and the compiler shows every `switch` where it is not handled.

### Error or "nothing"

`!T` and `?T` are different things, and good code tells them apart. In Clipper, parsing the `Range` header returns `error{Unsatisfiable}!?struct { u64, u64 }` — three outcomes in one type:

- `null` — the header is not understood; by HTTP rules it must be ignored;
- `error.Unsatisfiable` — understood, but there is no such range in the file: a 416 response;
- a pair of numbers — the range.

The type reads like a sentence, and the caller cannot confuse "did not understand" with "understood, but not allowed".

### defer and errdefer

```
const file = try dir.createFile("tmp.txt", .{});
defer file.close();

const buf = try a.alloc(u8, 4096);
errdefer a.free(buf);   // only if an error comes later
try fill(buf);
return buf;             // success: buf goes to the caller
```

`defer` runs on any exit from the block. `errdefer` — only on exit with an error. This solves the problem for which other languages invented destructors and `finally`: "release it unless you handed it over". The release code stands next to the acquisition code, and the order is the reverse of acquisition — as on a stack.

### Error return trace

In a debug build Zig remembers the path along which an error rose through `try`. If `main` returned an error, not only its name is printed but every line it passed through. This is not the call stack at the moment of the error but the path of its return — exactly what you need to understand where it came from.

### Price

**An error without data.** `error.NotNumber` cannot say which value failed to parse. When details are needed they are passed separately: Clipper's settings-loading functions take a pointer to a string where they write an explanation. It looks like a step back compared to languages where an error carries data. The reason is forced: an error in Zig is an integer, which makes it cheap (no allocation on error) — and a server must not allocate memory even when something has gone wrong.

**`catch return null` is easy to write.** One construct can either handle an error correctly or swallow one that must not be swallowed. The language guarantees that you made a decision, not that the decision is right.

**An accumulated error.** Sometimes `try` on every line turns the code into noise. Clipper's page writer (`src/out.zig`) does not return an error on buffer overflow; it sets a flag and checks it once at the end. This is a deliberate departure from the language's rule, and the compiler no longer watches it. The technique is worth using only when there is a single check at the end and it cannot be bypassed.
