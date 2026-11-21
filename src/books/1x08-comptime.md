## comptime: the same language at compile time

### Question: why another language for templates and generics?

In C generic code is written with macros — a language that knows nothing about types. In C++ with templates, which over time became a separate language with its own rules. In Rust with constrained generics plus macros for everything that did not fit into generics.

Zig answers: no second language. Any Zig code can be executed at compile time if everything it needs is known at compile time. The word `comptime` demands it.

### Types are values

```
fn Pair(comptime T: type) type {
    return struct { a: T, b: T };
}

const P = Pair(u32);
const p = P{ .a = 1, .b = 2 };
```

`Pair` is an ordinary function that takes a type and returns a type. The standard library's generic structures (`ArrayList(T)`, `HashMap(K, V)`) are built exactly this way. There is no separate syntax for generics: there are functions and values of type `type`.

### Strings processed at build time

The clearest example from Clipper is page templates. A template file is embedded in the program (`@embedFile`) and cut at `{{name}}` markers at compile time:

```
pub fn render(comptime src: []const u8, w: *W, ctx: anytype) void {
    comptime var rest: []const u8 = src;
    inline while (true) {
        const open = comptime std.mem.indexOf(u8, rest, "{{") orelse break;
        const close = comptime std.mem.indexOfPos(u8, rest, open, "}}")
            orelse @compileError("template: unclosed {{");
        if (open > 0) w.raw(comptime cp.lit(rest[0..open]));
        const name = comptime rest[open + 2 .. close];
        @field(@TypeOf(ctx.*), name)(ctx, w);
        rest = comptime rest[close + 2 ..];
    }
    if (rest.len > 0) w.raw(comptime cp.lit(rest));
}
```

`std.mem.indexOf` is the same function that runs at run time. `inline while` is unrolled: there is no loop in the program, only a straight sequence "write a piece, call a method". `@field(Type, name)` finds a method by the name from the template; if there is no such method, it is a build error. `@compileError` is an error message written by the programmer.

### Reflection

`@typeInfo(T)` returns a description of a type as an ordinary struct: fields, their types, enum variants. It can be walked with `inline for` to generate code:

```
fn countFields(comptime T: type) usize {
    return @typeInfo(T).@"struct".fields.len;
}
```

The standard library's formatting, JSON serialization and test comparisons are built this way.

### Where the limit is

**Build time.** The compiler's interpreter is slow. Every compile-time operation costs hundreds of times more than at run time. Hence `@setEvalBranchQuota`: without it the compiler will stop a long computation, deciding it is stuck in a loop. In Clipper re-encoding all interface strings at compile time is a noticeable part of the minute the build takes.

**Large data.** At first the built-in books (this one among them) were going to be parsed from Markdown at compile time. That was dropped: the interpreter would chew through a hundred and fifty kilobytes of text slowly, and on every build. Instead — a separate program the build system runs as a step, caching the result. The rule: at compile time — what is small and tied to types; what is large and linear — to a build step.

**`anytype`.** A parameter without a type accepts anything, and the check happens inside the function. The error looks like a chain of several call levels, and reading it takes skill. This is duck typing checked by the compiler: convenient, but the contract of what is needed from the type is written down nowhere.

### Why this decision is principled

Many languages separate the "program language" from the "metaprogram language". Zig deliberately merges them. The price is a slow interpreter and error messages that are hard to read. The gain is that there is no second language to learn, and a metaprogram is debugged with the same tools as a program. Of all the language's decisions this is perhaps the boldest and the most consistent.
