# Part IV. Why Zig is the way it is

## What was done by necessity

Book 0 distinguishes Clipper's decisions as principled and forced: principled ones were chosen because that is right, forced ones because the frame or the resources allowed nothing else. Languages are the same. A good understanding of a language starts with telling one from the other: the principled will stay, the forced will change as soon as circumstances change.

Below are Zig's decisions that, by all appearances, are forced. The words "by all appearances" matter here: this is an outside analysis based on code, release notes and the project's history, not statements by the language's authors.

### 1. Instability before 1.0

Every minor version breaks code. It looks like carelessness, but it is a deliberate bet: break things now, while there are few programs, so as not to drag a design mistake along for decades.

Analogies show why this is reasonable.

**Python 2 -> 3.** The transition, which fixed a mistake in the string model (bytes and text were mixed up), took more than ten years and split the community. Since then Python has had no fourth major version and, by all appearances, will not: the price of an incompatible transition turned out so high that the language prefers to accumulate compromises rather than repeat it. A forced decision — forced by past trauma.

**C++ and binary compatibility.** The C++ standard library cannot fix known failures (slow regular expressions, the design of some containers), because changing object layout would break already-built programs. The language is locked in by its own success.

Zig looks at both examples and chooses a third way: break often while it is not 1.0, and promise no compatibility until it is sure of its decisions. The price — for projects like Clipper: a pinned version and a debt that grows with every release.

### 2. The rewritten I/O in 0.15

In 0.15 the reader and writer interfaces were rewritten entirely. The old ones were generic: each kind of stream produced its own type, code bloated with copies, and the buffer lived outside the interface. The new ones have the buffer inside and fewer code copies. According to the release notes, this prepares a new I/O model that should bring async back to the language.

The necessity here is that the old interface was a mistake that could be fixed only incompatibly. The later, the more expensive. For Clipper this means: moving to 0.15 means rewriting every place that uses the standard library's I/O.

Along the way, according to the release notes, deflate in the rewritten module temporarily kept only decompression. If that is so in your version, programs that compress (like Clipper's snapshot) stay on 0.14 or write compression themselves. Check the notes for your version.

### 3. The vanished async

Early Zig versions had `async` and `await` at the language level. Since 0.11 they are gone: the new compiler, written in Zig itself, did not support them, and the feature was removed rather than left broken. A forced decision: rewriting the compiler turned out more important than keeping one feature.

The consequence for the backend: the event loop is written by hand on top of `epoll` or `select`. Clipper did exactly that, and for a dumb server it is more of a plus: every wait is visible. But for a server with a thousand concurrent long operations it is a serious lag behind Go or Rust.

### 4. LLVM and own backends

Historically Zig compiled through LLVM. LLVM gives excellent optimization and many targets, but it is huge, slow and changes on its own schedule. Zig is gradually writing its own code generators — first for x86_64 debug builds, so that they build in fractions of a second. A forced decision: dependence on someone else's huge project determined the compiler's speed and which targets were possible at all.

### 5. Support for old systems

Zig officially supports only modern versions of Windows. This is not a principle of "old is unneeded" but a necessity: every supported version means testing, and the project's resources are limited. Clipper works on XP not thanks to Zig but because the language does not get in the way: the standard library lets you avoid calling what is not there, and a system function can be declared in one line. As soon as the standard library starts calling something new in program startup code, XP will fall off — and nobody is obliged to prevent it.

### 6. Unmanaged containers

An `ArrayList` with an allocator inside was convenient but contradicted the principle "the call shows where memory is allocated". In 0.15 the kind without an internal allocator became the default. This is not forced by circumstances but forced by its own principle: the language is catching up with itself.

### How to tell forced from principled

A simple sign: a principled decision is explained in one sentence about what kind of language they want to make ("no hidden control flow"). A forced one is explained with a story of what happened ("the new compiler did not support it"). The first is worth learning as a foundation. The second — as the current state of things, which will change.
