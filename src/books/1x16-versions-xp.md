## Zig 0.14, later versions and Windows XP

### Question: why is Clipper on 0.14 specifically?

The short answer: 0.14 is a preservation. It is the version on which it has been checked that a program without a C library builds for Windows XP and starts on it — and the only one where this has been checked. Any other version means checking again, and every new Zig version makes that check more expensive.

The long answer lies in how a Zig program ends up on XP at all.

### Zig does not support XP — and does not get in the way

Officially Zig supports only modern Windows. But the target `x86-windows.xp` exists: the compiler knows the minimum version is XP and can generate code for it. Beyond that everything depends on which system functions the program calls. If even one function appeared after XP, the XP loader will refuse to start the program — not at the moment of the call, but immediately, at load time.

So the task reduces to one thing: no function in the import table may be newer than XP. Here is what turned up on 0.14.1.

| what | where from | what was done |
| version 6.0 in the PE header | the linker | after the build a separate program, pe-version, patches the header to 5.1 |
| SRW locks (Vista) | std.Thread.Mutex | building with .single_threaded = true |
| RtlGetSystemTimePrecise (Windows 8) | std.time on Windows | own time via GetSystemTimeAsFileTime in src/sys.zig |
| the same time function | the standard library's TLS client | the XP build has no outgoing https at all |
| memory-mapping a file | not in std for Windows | own declarations of CreateFileMapping and MapViewOfFile |
| dual-stack IPv6 | absent in XP | the server silently listens on IPv4 only |

Each row is a place where Zig's standard library (or the linker) pulls the program toward newer Windows and the project steers it away. This is not a fight with the language: Zig lets you avoid a standard library function and declare a system function yourself in one line with `extern "kernel32"`. But it is ongoing work, and its result holds only for the standard library version it was checked on.

### What changes in later versions

A caveat is needed here: this chapter did not check 0.15 or 0.16 on XP. What follows is about direction, not specific functions.

- **0.15 rewrote I/O.** New reader and writer interfaces replaced the old ones; code that reads and writes through the standard library has to be rewritten. Every rewritten path means new system calls that must be checked against the import table again.
- **Next — a new I/O model.** According to the release notes, the rewrite prepares the return of async through a common I/O interface. The more the standard library does for the program, the more system functions it chooses by itself — and the greater the chance that one of them is newer than XP.
- **Own backends and linker.** Program startup code and linking change along with them. Patching the PE header on 0.14 is needed because of the 0.14 linker's behaviour; a new linker may behave differently — better or worse for XP.

The overall direction is clear: Zig is moving toward a convenient standard library for modern systems. That is right for the language and inconvenient for XP. Each version makes XP not impossible but more expensive.

### "Made differently"

The main thing to understand here: for someone writing servers, Zig 0.15 is in many ways a different language, although the syntax is almost the same. What changed:

- the reader and writer interfaces (what every byte of a server passes through);
- the default containers (`ArrayList` without an allocator inside);
- what is considered the right way to wait for I/O.

Clipper's code will survive the transition where it works with byte slices: HTTP parsing, the snapshot format, templates, the journal. And will not survive without rewriting where it touches the system and the standard I/O: `src/sys.zig`, `src/net/`, frame compression, exports, archive parsing. This is no accident: the dependence on the standard library is deliberately gathered in a few files.

### What to choose for your project

If the target is modern systems, take a fresh Zig and upgrade along with the language: that way the debt does not pile up.

If the target is old systems (XP, Windows 7, old hardware), pin the version on which this has been checked, keep the compiler in the project folder and upgrade only when you are ready to check the import table again and run the program on a real old system. Clipper chose the second. The price is a lagging language and a growing debt. The gain is one executable that works from XP to Windows 11.

A last honest note: Clipper has not yet been run on real Windows XP. The build, the PE header and the import table have been checked, and the 32-bit build has been run on Windows 11. The preservation is done; a check on a live XP is the next step.
