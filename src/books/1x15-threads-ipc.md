## Threads, processes and communication between them

### Question: threads or processes?

A server that wants to use several cores has two paths. Threads share memory: fast to exchange data, easy to corrupt someone else's. Processes share only what they were explicitly given: slower to exchange, but one crashing does not touch the others. Zig has both, and the choice between them is architectural, not syntactic.

### Threads in the standard library

```
const std = @import("std");

fn work(counter: *std.atomic.Value(u64), n: u64) void {
    for (0..n) |_| _ = counter.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var counter = std.atomic.Value(u64).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, work, .{ &counter, 100_000 });
    for (threads) |t| t.join();
    std.debug.print("{d}\n", .{counter.load(.monotonic)}); // 400000
}
```

`std.Thread.spawn` takes a function and a tuple of arguments; the types are checked at compile time. `std.atomic.Value(T)` is an atomic variable, and the memory order (`.monotonic`, `.acquire`, `.release`, `.seq_cst`) is given explicitly on every operation. The language does not choose it for you: the strictest order is slower, the weakest is easy to get wrong.

For anything more complex than a counter there are `std.Thread.Mutex`, `std.Thread.RwLock`, `std.Thread.Condition`, `std.Thread.Pool`.

There is no type-level "safe transfer between threads" like Rust's `Send` and `Sync`. The compiler will not find a data race. Only care will, or a thread sanitizer when building C parts. This follows directly from giving up an ownership model.

### Why Clipper is single-threaded

The first reason is design: a request is short, a second thread will not speed it up, and locks on shared state would make the server more complex (book 0, the page about the event loop).

The second reason is Windows XP. `std.Thread.Mutex` on Windows is built on SRW locks, which appeared in Vista. A program that calls such a mutex will not start on XP: the loader will not find the function. That is why the server is built with `.single_threaded = true` — then the standard library removes locks entirely.

There are threads in the project nonetheless — in the load-testing tool `tools/load.zig`. It is built for the build machine, not for XP, and can afford sixty-four threads with an atomic counter of remaining requests.

### Processes and communication between them

To use several cores without threads, Clipper starts several processes (`-w N`). They need to coordinate, and here is what they use — a good list of inter-process techniques without a single message queue:

| technique | Linux | Windows | why |
| a shared listening socket | inherited through fork | inherited through CreateProcessW | everyone accepts connections |
| socket number and the rest | memory after fork | the --worker command-line flag | the worker knows what it was given |
| a shared store file | file | file | data |
| a file lock | flock | LockFileEx | a queue of writes |
| a shared snapshot | mmap of one file | MapViewOfFile of one file | the catalog in one physical memory |
| an accept gate | not needed | a system mutex | only one process waits in accept |
| is the main process alive | getppid | WaitForSingleObject on a handle | the worker leaves after the main one |

The most interesting part is that all communication goes through files and system objects, not messages. A worker does not ask its neighbours what changed: it reads the journal on from where it stopped. This is slower than shared memory but needs no protocol and survives the crash of any participant.

### Question: why is a handle passed as a string on Windows?

On Linux after `fork` the child is a copy of the parent, and all variables are in place. Windows has no `fork`. A new process starts from scratch, and the only things that can be passed to it are inherited handles and the command line. So the socket number, the main process number and the gate handle are written as numbers into the `--worker` flag, and the worker turns the numbers back into handles. In Zig that is one line: `@ptrFromInt(number)`.

### Price

Processes cost more memory than threads: each has its own buffers and caches. Exchange through a file is slower than through memory. Writes do not scale: processes write in turn. But there is not a single data race in memory — because there is no shared memory that anyone writes to.
