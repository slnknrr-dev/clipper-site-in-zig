## HTTP by hand

### Question: why write your own HTTP parser?

Because in an event loop bytes arrive in pieces. The parser must be able to say three things: "the whole request, here it is", "not enough yet, wait for more", "this is not HTTP, close it". And it must do so without allocating memory: everything it returns is slices into the connection buffer.

### The result type

```
pub const Parsed = union(enum) {
    ok: Request,
    incomplete,
    fail: u16, // response code: 400, 405, 411, 431, 501, 505
};
```

A tagged union is the natural type for parsing: three different outcomes with different data, and a `switch` must handle them all. The failure here is not an `error` but a variant with a response code: it is an expected outcome that turns into a response to the client, not an exceptional situation.

### Strictness

Clipper's parsing is strict: lines are separated only by `\r\n`, the header is no longer than 8 KB, no `Host` — 400, `Transfer-Encoding: chunked` in a request — 501, a POST without a length — 411. Strictness is protection: every leniency ("let's also accept `\n` without `\r`") is a place where two parsers will understand one request differently, and that is a class of attacks on proxies.

### Slices instead of copies

`Request` is a set of slices: the method, the path, the query string, the values of the needed headers. They all point into the connection buffer. While the request is being handled the buffer is left alone; after the response it is reused. No strings on the heap.

Address and form parameters are decoded (`%41` -> `A`) into the request arena — the only place that needs copying, because a decoded string is shorter than the original and does not match it byte for byte.

### Testing on hostile input

The parser is a function "bytes -> result", without sockets. So it can be fed random and corrupted bytes by the million:

```
test "random input does not crash the parser" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    for (0..60_000) |_| {
        const n = rnd.uintLessThan(usize, buf.len);
        rnd.bytes(buf[0..n]);
        _ = parse(buf[0..n]); // no panic and no out-of-bounds access allowed
    }
}
```

The seed is constant — a failed case repeats on every run. The test is built in Debug, where bounds and overflow checks are on: any parser bug becomes a stop with an address, not silent corruption.

### Price

Your own HTTP parser means responsibility for every corner of the specification. Clipper supports HTTP/1.0 and 1.1 and honestly refuses everything else (HTTP/2 — 505). For a server behind a proxy that is enough; for a server that must talk to the whole world directly, it is not.
