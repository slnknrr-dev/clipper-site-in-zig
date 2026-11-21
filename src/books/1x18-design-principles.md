## What was done on principle

### No hidden control flow

If a line of code does not look like a function call, it does not call a function. No operator overloading, no exceptions, no properties with getters, no destructors. `a + b` is addition and only addition. A function can be left only through `return`, `try` or its end.

The price: verbosity. Adding vectors is written as a function call, not a plus. The gain: code can be read top to bottom without keeping in mind what might have happened behind each line.

### No hidden memory allocations

No language construct allocates heap memory by itself. No growing strings, no closures capturing their environment, no implicit heap copies. Memory is allocated only by whoever has been handed an allocator.

This is the principle Clipper's design stands on: "nothing is allocated on the request path" is checked by reading signatures.

### No macros and no preprocessor

Metaprogramming is the same language at compile time. Conditional compilation is an `if` on a value known at compile time. Including a file is `@import`, which returns a value.

### Explicitness over brevity

Type casts are explicit only. Overflow is an error, and wrapping is written with a separate operator. An unused variable is a compile error. An unused function result is a compile error unless explicitly discarded (`_ = f()`).

The last two rules irritate the most, especially while debugging. But they are consistent: the language does not believe you "just forgot" and demands that you say so out loud.

### Where the principles are broken

Honesty requires saying this too.

- **`anytype`** — a parameter without a type. The contract of what is needed from the argument is written down nowhere; the error shows up deep inside. A concession to convenience, without which generic code would become heavy.
- **`std.debug.print`** ignores write errors — that is, silently does what the language does not let you do silently. A concession to debugging.
- **The ReleaseFast and ReleaseSmall modes** remove checks, and undefined behaviour returns. A concession to speed: the language gives a choice, but the choice is dangerous.
- **Use of freed memory** is not caught in production builds. The principle "the language does not let you err unnoticed" is not met here, and closing this without an ownership model like Rust's seems impossible.

### Summary

Zig is a language that refuses to decide for the programmer. It does not choose the string encoding, the allocator, what to do on overflow, or whether to flush the output buffer. For an application program this is inconvenient: nothing was decided for you. For a server that must be dumb enough, it is exactly what is needed: every decision is visible, and every one can be made by yourself.

Clipper is a test of this idea on a whole site. Book 0 tells what came of it.
