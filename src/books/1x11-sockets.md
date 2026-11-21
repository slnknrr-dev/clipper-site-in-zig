## Sockets and the event loop

### The simplest server

```
const std = @import("std");

pub fn main() !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", 3000);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();
        try conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello");
    }
}
```

This works and teaches that HTTP is just bytes in a socket. But such a server serves one connection at a time: while a slow client reads its response, the others wait.

### Non-blocking sockets and readiness

An event loop turns the model over. Sockets are switched to non-blocking mode: a read when there is no data does not wait but immediately returns the `WouldBlock` error. And the system reports which sockets are ready:

- `select` — the oldest way, available everywhere including Windows XP; walks all sockets on every call;
- `poll` — the same without a limit on the socket number;
- `epoll` (Linux) — register a socket once, and the system returns only the ready ones;
- IOCP (Windows) — an "operation completed" model rather than "socket ready";
- `io_uring` (newer Linux) — a queue of operations in memory shared with the kernel.

The loop: ask the system what is ready; for each ready socket, read what arrived or finish writing what did not go out; repeat. All in one thread.

### Choosing an implementation at compile time

```
const builtin = @import("builtin");
pub const is_windows = builtin.os.tag == .windows;
pub const Socket = if (is_windows) std.os.windows.ws2_32.SOCKET else std.posix.socket_t;
pub const Poller = if (is_windows) SelectPoller else EpollPoller;
```

`builtin.os.tag` is known at compile time, and an `if` on it chooses a type. The branch not chosen is not compiled at all — it may refer to functions that do not exist on this system. There is no preprocessor, and none is needed: conditional compilation is an ordinary expression.

Both pollers have the same methods: `init`, `add`, `modify`, `remove`, `wait`. The interface is declared nowhere — the contract is checked by the server loop building for both systems. This is compile-time duck typing. The price: an edit on one system may break the other, and you can find out only by building for the other.

### A response without copying

A finished response is several pieces of memory: the header, a body from the cache, a body from the mapped file. The system call `sendmsg` (Linux) or `WSASend` (Windows) takes a list of pieces and sends them in one call. There is no need to copy them into one buffer.

### Winsock peculiarities found in practice

On Windows a socket inherited by a child process is blocking again: the "non-blocking" flag lives in process memory. And a non-blocking `accept` in several processes on one socket can leave one of them waiting inside the call. Neither comes from the documentation; both come from a hung server. More in book 0, the page about the event loop.

### Why not `std.http.Server`

The standard library has an HTTP server. It works on top of a blocking connection and is meant for the "thread per connection" model or for simple cases. An event loop needs a parser that accepts bytes in pieces and can say "not enough yet". That is the next chapter.
