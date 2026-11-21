# Part VII. Language and conclusions

## Why Zig, and why 0.14

The language was chosen for the task, not the other way round. The task: a program hands the kernel pointers to bytes already in memory, allocating nothing along the way; it parses hostile files; and it builds for a twenty-year-old system without a single external library. A detailed look at the language, how it works and why it is the way it is, is in book 1, "Zig for the backend". Here — only the fork.

### Paths

| what is needed | C | C++ | Rust | Zig |
| bounds checks in a production build | no | partly | yes | yes |
| compile-time evaluation in the same language | no | in its own sublanguage | limited, plus macros | yes |
| no hidden allocations or calls | yes | no | almost | yes |
| compile-time ownership guarantees | no | no | yes | no |
| cross-compilation out of the box | no | no | partly | yes |
| language stability | yes | yes | yes | no |

Garbage-collected languages (Go, Java, C#) are a dead end before any comparison: "zero allocations per request" would have to be won back from the runtime.

**C** — bounds checks are manual, templates need a second generator language, and the frame requires doing without the C library, which takes away half the point of writing in C.

**C++** — there are enough features, but too many: the line `a = b` may allocate memory, throw an exception and call user code. For a program whose main property is "nothing is allocated on the request path", that property has to be checkable by reading the code.

**Rust** is the strongest rival. Its ownership guarantees are real and catch at compile time what Zig catches at run time or not at all. Three things worked against it here: the program's most valuable spot — slices inside a mapped file and buffers that outlive a request — is exactly where Rust demands `unsafe`; its ecosystem is built on packages, which the frame forbids; and Rust's standard library dropped Windows XP long ago.

### Better — under other conditions

For a team of twenty and code that will live ten years, Rust is better: ownership guarantees repay the cost of learning. For a service with a database and ordinary requirements, Go is better: it is faster to develop in, and garbage collection is no obstacle there. Zig wins precisely in this frame: one author, a dumb server, no dependencies, ancient targets.

### Why the version is pinned

The project builds only with Zig 0.14.x: `build.zig` refuses to work on another version. There are four reasons: pinning is cheaper than supporting several versions; 0.15 completely rewrote the standard library's I/O; according to the release notes, the rewritten deflate module kept only decompression, and Clipper compresses its catalog with exactly that; the XP build was checked on 0.14.1 and would need rechecking on another version. The two middle reasons describe someone else's code that keeps changing — before upgrading they are worth checking against the release notes.

Pinning is a debt, and it grows. That is why everything most dependent on the standard library is gathered in a few places: `src/sys.zig`, `src/net/net.zig`, the compression calls in `src/snapshot.zig` and `src/import/common.zig`. The rest of the code works with byte slices. A dependency that cannot be removed should at least be gathered in one place.
