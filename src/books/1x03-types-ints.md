## Integers: width, sign and overflow

### Question: why `u3`?

In Zig an integer can be of any width from 0 to 65535 bits: `u3`, `i7`, `u24`, `u128`. It looks odd until you need it. In Clipper the site's features are stored as an enum backed by `u4` — twelve values fit in four bits, and the compiler will not let you assign fifteen. A member's rights are a `u8` where each bit is a right. A type's width is documentation the compiler checks.

### Overflow is an error, not behaviour

```
const std = @import("std");

pub fn main() void {
    var a: u8 = 250;
    a += 10; // in Debug and ReleaseSafe — a stop: integer overflow
    std.debug.print("{d}\n", .{a});
}
```

In C unsigned overflow wraps modulo, and signed overflow is undefined behaviour the optimizer may rely on however it likes. In Zig overflow in an ordinary operation is an error. In Debug and ReleaseSafe builds it stops the program and names the place; in ReleaseFast and ReleaseSmall the check is removed and the behaviour is undefined.

If wrapping is needed, it is written explicitly:

- `a + b` — overflow is an error;
- `a +% b` — modulo 2^N;
- `a +| b` — saturating: no more than the maximum and no less than the minimum;
- `@addWithOverflow(a, b)` — a pair: the result and an overflow bit.

The same goes for `-`, `*` and shifts. Every unsigned subtraction is a place where you must decide what should happen and record the decision with an operator. Clipper's parsing of the `Range` header is written this way: `len -| n` — if more is requested than exists, the result is zero, not a huge number.

### Why this matters for a server

The bug Clipper found with a random-input test was exactly of this kind: a request for the last five bytes of an empty file computed "zero minus one". In ReleaseSafe the server stopped. In C the same bug would have produced a length of 18 quintillion and a read of someone else's memory. The check turned a vulnerability into a failure — a loud one, with an address.

That is why Clipper builds ReleaseSafe by default: fast code with checks. ReleaseFast is faster by percents and more dangerous by orders of magnitude.

### Casts — only explicit

```
const big: u32 = 300;
const small: u8 = @intCast(big);   // checked: 300 does not fit — a stop
const low: u8 = @truncate(big);    // drops the high bits: 44
const f: f64 = @floatFromInt(big);
```

Zig widens implicitly only where the value certainly fits: `u8` to `u32` — yes, back — no. Every narrowing is visible in the code and named by meaning: "check that it fits" or "cut off".

### `usize` and `comptime_int`

`usize` is an integer as wide as a pointer; it is the type of lengths and indexes. The literal `300` by itself has type `comptime_int` — an arbitrary-precision integer that exists only at compile time. So `const x = 1 << 100;` is legal as long as nobody tries to put `x` into a variable of a real type.

### Price

Explicitness is verbose. Mixed-type arithmetic needs casts, and in the first days that is irritating. In return you get a language where the text shows where overflow can happen — and where it cannot.
