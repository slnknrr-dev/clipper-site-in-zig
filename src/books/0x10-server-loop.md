# Part IV. The server

## Event loop, threads and processes

### Fork

How the server serves many connections at once and how it uses more than one core.

### Paths

1. **A thread per connection.** Easiest to write: the request code is sequential.
2. **A thread pool with a shared queue.**
3. **An asynchronous runtime** (coroutines, promises).
4. **One thread with non-blocking sockets** — an event loop.
5. **Several processes**, each with its own loop, on one listening socket.

And a way to learn that a socket is ready: `select`, `poll`, `epoll` (Linux), IOCP (Windows), `io_uring` (newer Linux).

### Choice

Path 4, and for several cores path 5. One thread; sockets are non-blocking; readiness is reported by `epoll` on Linux and `select` on Windows. Connection slots — 1024 — are allocated at startup. Request memory is three preallocated buffers: the arena (24 MB), the page body (6 MB), the finished response (8 MB). The request path never asks the system for memory.

Why: the work per request is short — find in mapped memory, concatenate, send. When a request takes microseconds, a second thread speeds up nothing but brings locks on all shared state. A single-threaded server has no races not because they are carefully closed off, but because they have nowhere to come from. That is what "dumb enough" means.

Several processes (`-w N`): the main one opens the socket and starts the workers; each is the same single-threaded server. What they share is the store file and the snapshot file. Before reading, a worker catches up on others' writes; a write request runs entirely under a lock on the store file.

| processes | pages from cache | past the cache |
| 1 | 72,200 per second | 15,200 per second |
| 2 | 123,100 | 29,900 |
| 4 | 170,900 | 50,100 |
| 8 | 195,300 | 68,000 |

### What turned up on Windows

On Linux the workers are a `fork` after `listen`: the kernel hands each connection to exactly one of them. Windows has no `fork`; workers are new processes with an inherited socket, and two things turned up that the documentation does not state plainly.

The "non-blocking" flag in Winsock lives in process memory, not in the kernel: an inherited socket is blocking again, and the worker must switch it itself.

A non-blocking `accept` is "check, then wait". Two processes check at the same time, one gets the connection, and the other is left waiting inside `accept` together with all its connections. The server froze under load, and only with several processes. The fix is an accept gate: a system mutex; only its owner accepts. Windows hands a crashed worker's mutex to the next one.

Both findings came not from reading but from a hung server. Portability is a property you test, not one you deduce.

### Dead ends

**A thread per connection with a thousand connections** — a thousand stacks and a scheduler busy switching. A dead end for a server that must hold slow clients.

**Threads under the XP requirement.** The Zig standard library's locks rely on functions that appeared after XP. Multithreading here is not just complexity but a direct violation of the frame. Details — book 1, the chapter on building.

**An asynchronous runtime (path 3).** Zig 0.14 has none: the former async support was removed from the language and has not yet returned. A custom runtime is exactly what a "dumb server" avoids.

### Better — under other conditions

**IOCP on Windows.** `select` walks all sockets on every pass. IOCP scales better but needs a different model (completion of an operation rather than readiness) and a second loop implementation. `select` was chosen because it is the same from XP to 11.

**io_uring on newer Linux** — fewer system calls per request. Not on all kernels, and not on XP.

**Offloaded long work.** The main price of path 4 is that any long piece of work stops everyone. Parsing a large PDF takes seconds; asking a neighbouring site during federated sign-in takes up to eight seconds. Better is a separate worker process for such tasks and a queue to it. That is one step up in server intelligence, and it has not been taken.

### Price

One thread — one core per process. Writes do not scale at all: processes write in turn and are bound by the disk. Each worker has its own buffers and caches: eight processes are eight times a hundred megabytes. With workers on Windows new connections are accepted more slowly than with one process (the gate is a bottleneck). The Linux branch builds but has not been tried in operation.
