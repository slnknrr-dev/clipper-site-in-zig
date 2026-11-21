# Part III. The standard library and the system

## A map of the 0.14 standard library

Zig's standard library is Zig source code that lies next to the compiler (`lib/std/`). It can and should be read: the documentation lags behind, the code does not. This is the first habit worth developing.

### What it has for a server

| module | what it gives |
| std.mem | slices: search, comparison, splitting, sorting |
| std.fmt | formatting and number parsing |
| std.ArrayList, std.HashMap, std.StaticStringMap | containers |
| std.fs | files and directories |
| std.posix, std.os.linux, std.os.windows | system calls |
| std.net | addresses and simple sockets |
| std.http | an HTTP client and a simple server |
| std.crypto | hashes, ciphers, key exchange, signatures, Argon2, a TLS client |
| std.compress | flate (deflate), gzip, zlib — compression and decompression; zstd — decompression only |
| std.unicode | UTF-8 and UTF-16 |
| std.Thread | threads and synchronization primitives |
| std.testing | assertions and the testing allocator |
| std.Build | the build system |

### What it lacks — and what follows

**A TLS server.** There is a client, no server. Clipper built a TLS 1.3 server from `std.crypto` primitives: X25519, AES-GCM, ChaCha20-Poly1305, HKDF, ECDSA and Ed25519. This is possible precisely because the primitives are in the library and are of good quality.

**RSA signatures.** That is why Clipper does not accept RSA keys.

**zstd compression.** Decompression only. That is why Clipper compresses with deflate.

**Single-byte encodings.** Code page tables are data, and the library does not keep them.

**Asynchronous I/O.** The former async support in the language was removed in 0.11 and has not yet returned. The event loop is written by hand on top of `epoll` or `select`.

**A database, a template engine, a web framework.** There are none and will be none: these are packages, not a standard library.

### Managed and unmanaged containers

In 0.14 there are two kinds of containers. `std.ArrayList(T)` keeps an allocator inside (managed). `std.ArrayListUnmanaged(T)` does not, and the allocator is passed to every call that may allocate:

```
var list: std.ArrayListUnmanaged(u32) = .{};
defer list.deinit(a);
try list.append(a, 42);
```

The unmanaged kind is one word smaller and, more importantly, every call shows where memory is allocated. In 0.15 the unmanaged kind became the default. An example of how the language gradually moves toward one principle — explicit allocation — and pays for it with incompatibility.

### Question: is it worth writing your own?

Clipper wrote its own in many places: HTTP, ZIP, PNG, PDF parsing, the B+ tree. The rule experience led to: take from the standard library everything where it gives a **primitive** (a hash, a cipher, compression, sorting), and write your own where it gives a **policy** (how to parse a request, how to hold connections). Primitives are hard to get right; policy is hard to get fitting.
