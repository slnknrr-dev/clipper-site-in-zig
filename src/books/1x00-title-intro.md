---
title: Zig for the backend: why it is the way it is
year: 2026
annotation: A textbook of fundamental Zig for server programming — from a proper "Hello, World" with colored output to sockets, memory-mapped files and builds for Windows XP. For those who want to understand the language, not just write in it: every feature is explained through the problem it solves and what was paid for it. It also examines where Zig is the way it is on principle and where by necessity. Text — CC BY-SA 4.0, code — MIT. Sources: https://github.com/slnknrr-dev/clipper-site-in-zig
---

## From the author

**Zig for the backend: why it is the way it is**

Yury Slinkin, 2026

This book is a companion to book 0, "Inside Clipper". That one tells how the site works and what decisions were made. This one is about the language it is written in, and why the language is built so that such decisions come naturally in it.

### Who it is for

For someone who already writes in some language and asks questions deeper than "how do I write this". Why does Zig have no exceptions? Why is the memory allocator passed as a parameter? Why is a string literal a pointer to a zero-terminated array rather than a string? Why did version 0.15 break half the programs written for 0.14, and why do the language's authors think that is how it should be?

If you need a recipe, this book will be slow. If you need to understand, it is for you.

### Version

Everything in the book applies to Zig 0.14.1 — the version Clipper is built with. The language has not reached 1.0, and the standard library changes between versions. Where 0.15 and later work differently, that is said; where something is said from memory of release notes rather than checked in code, that is said too. If the book and the compiler disagree, the compiler is right.

### How to read

Chapters go from simple to complex, but each starts with a question and ends with a price. The first chapters are output, numbers, pointers, encodings. The middle is errors, memory and compile-time evaluation: the three things that make Zig Zig. Then the standard library, files, sockets, HTTP, building, tests, threads and inter-process communication: everything a server needs. Then how 0.14 differs from later versions and why Clipper is frozen on 0.14 for the sake of Windows XP. The last two chapters are about why the language is the way it is: where its decisions are principled and where they are forced by circumstances.

Examples are short programs built with `zig run file.zig`. Where an example is taken from Clipper, the file is named.

### Licenses

Text — CC BY-SA 4.0, code — MIT. Author: Yury Slinkin, 2026, slnknrr.dev@gmail.com. Sources: https://github.com/slnknrr-dev/clipper-site-in-zig
