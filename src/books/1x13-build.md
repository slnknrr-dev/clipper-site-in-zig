## Building: build.zig and cross-compilation

### The build file is a program

In Zig the build is described by a `build.zig` file in Zig itself. It is not configuration but code with conditions, loops and functions:

```
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "build mode") orelse .ReleaseSafe;
    const exe = b.addExecutable(.{
        .name = "clipper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    b.installArtifact(exe);
}
```

`build` does not build; it describes a graph of steps. The build system runs only the steps whose inputs changed and caches results by content.

### Cross-compilation is a flag

`zig build -Dtarget=x86-windows.xp` on a Windows 11 machine builds a 32-bit program for XP. `-Dtarget=x86_64-linux` — for Linux. No separate toolchains: the Zig compiler carries everything needed for each target. This is one of the main reasons the language is chosen for systems work even by people who do not plan to write in it: `zig cc` is a C cross-compiler.

### Steps that are programs

The strongest property: a build step can be a Zig program built for the build machine.

Example 1. The linker writes system version 6.0 into a Windows executable's header, and XP will not run such a file. Clipper builds a small program `pe-version` (`.target = b.graph.host`), runs it on the finished file and gets a fixed copy. One `build.zig` — programs for two different systems.

Example 2. The built-in books (this book is one of them) lie as Markdown in `src/books/`. The program `tools/books.zig` turns them into Zig source with ready strings in windows-1251, and the server imports it as a module. As long as the book files have not changed, the step does not run.

### Build options

```
const lang = b.option(Lang, "lang", "interface language") orelse .ru;
const options = b.addOptions();
options.addOption(Lang, "lang", lang);
exe.root_module.addOptions("config", options);
```

`zig build -Dlang=en` — the option arrives in the program as a constant of the `config` module, known at compile time. Code that depends on it is selected by a compile-time `if`, and only the needed branch remains in the finished program. This is how Clipper chooses the interface language and which books are built in.

### `single_threaded` and Windows XP

`.single_threaded = true` tells the compiler there are no threads. The standard library then removes its locks — and its mutex on Windows is built on SRW locks, which XP does not have. For Clipper this flag is not an optimization but a condition for running on XP.

Officially Zig supports only modern Windows. XP works because the standard library lets you avoid calling what XP lacks — but nobody promises that. The import table has to be checked by hand after every compiler update.

### Price

The build system's interface changes more often than the language itself. The build file is the first thing to break on a compiler update. This is one of the reasons the project is pinned to one version.
