//! zig build                 целевые сборки → .build/nt-i686-en-all/, nt-x86_64-en-nobook/ (Windows 10+),
//!                           .build/nt51-i686-ru-all/, nt51-x86_64-ru-all/ (Windows XP+),
//!                           .build/linux-x86_64-en-all/ (Linux), и сервер для этой машины → zig-out/bin/clipper
//! zig build dist            только целевые сборки
//! zig build host            только сервер для этой машины
//! zig build test            модульные и сквозные тесты (test/)
//! zig build run -- -p 3000  собрать и запустить
//! zig build load -- localhost 3000 /b/2   замер нагрузки (tools/load.zig)
//! zig build t9n             собрать ключи перевода интерфейса в src/t9n/*.t9n
//!
//! Параметры:
//!   -Dlang=ru|en      язык интерфейса и встроенных книг (по умолчанию ru)
//!   -Dbook0=false     без книги 0 (/b/0); по умолчанию она есть
//!   -Dbooks=true      встроить книги 1 (Zig, /b/1) и 2 (Web, /b/2); по умолчанию нет
//!   -Dvoice=false     без раздела /v (аудиокниги, чтецы, исполнители); по умолчанию он есть
//!   -Dogg=false       не принимать .ogg (Vorbis) в /v; по умолчанию принимается
//!   -Dm4a=true        принимать .m4a (AAC LC) в /v; по умолчанию нет. MP3 при -Dvoice — всегда
//!
//! Встроенные книги: src/books/ru/<книга>x<страница>-<тема>-<подтема>.md — русские,
//! src/books/<книга>x... — английские. Автор — администратор сайта /u/0.
//!
//! Цели: Linux x86_64 и Windows XP+ (x86, x86_64), без C-библиотеки:
//!   zig build -Dtarget=x86_64-linux
//!   zig build -Dtarget=x86-windows.xp

const std = @import("std");
const builtin = @import("builtin");

comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 14) @compileError("проект закреплён за Zig 0.14.x (см. BACKLOG_RU.md)");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Без -Doptimize сервер собирается ReleaseSafe: быстрый, но с проверками границ.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "режим сборки сервера (по умолчанию ReleaseSafe)") orelse .ReleaseSafe;
    const windows = target.result.os.tag == .windows;
    const lang = b.option(Lang, "lang", "язык интерфейса и книги 0: ru, en (по умолчанию ru)") orelse .ru;
    const book0 = b.option(bool, "book0", "встроить книгу 0, /b/0 (по умолчанию true)") orelse true;
    const books = b.option(bool, "books", "встроить книги 1 и 2: /b/1 (Zig) и /b/2 (Web) (по умолчанию false)") orelse false;
    const zstd = b.option(bool, "zstd", "свой zstd: флаг -zstd и команда clipper zstd (по умолчанию true)") orelse true;
    // PDF и DjVu — экспериментальные: разбор есть в программе, загрузку включают флаги -pdf и -djvu
    const pdf = b.option(bool, "pdf", "разбор PDF (экспериментально); загрузку включает флаг -pdf (по умолчанию true)") orelse true;
    const djvu = b.option(bool, "djvu", "разбор DjVu (экспериментально); загрузку включает флаг -djvu (по умолчанию true)") orelse true;
    // Раздел /v: всё, что загружено, перекодируется в MP3 CBR 128 кбит/с (MPEG-1 Layer III)
    const voice = b.option(bool, "voice", "раздел /v: аудиокниги, чтецы и исполнители (по умолчанию true)") orelse true;
    const ogg = b.option(bool, "ogg", "принимать .ogg (Vorbis) в /v (по умолчанию true)") orelse true;
    const m4a = b.option(bool, "m4a", "принимать .m4a (AAC) в /v (по умолчанию false)") orelse false;
    const fmt = Formats{ .pdf = pdf, .djvu = djvu, .voice = voice, .ogg = voice and ogg, .m4a = voice and m4a };
    const gen = generated(b, lang, book0, books, zstd, fmt);

    const exe, const bin = server(b, target, optimize, gen);
    const install_exe = &b.addInstallFileWithDir(bin, .bin, exe.out_filename).step;
    b.getInstallStep().dependOn(install_exe);
    b.step("host", "только сервер для этой машины → zig-out/bin (без целевых сборок)").dependOn(install_exe);

    // Целевые сборки в .build/ОС-АРХИТЕКТУРА-ЯЗЫК[-КНИГИ]/; язык и книги у каждой свои,
    // -Dlang/-Dbook0/-Dbooks их не меняют. -all — книги 0, 1, 2; -nobook — без книг;
    // без суффикса — только книга 0. nt51 — Windows XP+, nt — Windows 10+, linux — Linux (без libc).
    // Папка в дереве проекта, а не в zig-out: её не трогает -p и не чистит смена префикса.
    const dist = b.step("dist", "целевые сборки: .build/nt-i686-en-all, nt-x86_64-en-nobook, nt51-i686-ru-all, nt51-x86_64-ru-all, linux-x86_64-en-all");
    const put = b.addUpdateSourceFiles();
    const Dist = struct { name: []const u8, query: std.Target.Query, lang: Lang, all: bool };
    for ([_]Dist{
        .{ .name = "nt-i686-en-all", .query = .{ .cpu_arch = .x86, .os_tag = .windows }, .lang = .en, .all = true },
        .{ .name = "nt-x86_64-en-nobook", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .lang = .en, .all = false },
        .{ .name = "nt51-i686-ru-all", .query = .{ .cpu_arch = .x86, .os_tag = .windows, .os_version_min = .{ .windows = .xp } }, .lang = .ru, .all = true },
        .{ .name = "nt51-x86_64-ru-all", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .os_version_min = .{ .windows = .xp } }, .lang = .ru, .all = true },
        .{ .name = "linux-x86_64-en-all", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .lang = .en, .all = true },
    }) |d| {
        const t = b.resolveTargetQuery(d.query);
        _, const bin_d = server(b, t, optimize, generated(b, d.lang, d.all, d.all, zstd, fmt));
        const file = if (t.result.os.tag == .windows) "clipper.exe" else "clipper";
        put.addCopyFileToSource(bin_d, b.fmt(".build/{s}/{s}", .{ d.name, file }));
    }
    dist.dependOn(&put.step);
    b.getInstallStep().dependOn(dist);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(install_exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "запустить clipper").dependOn(&run.step);

    // Модульные тесты живут рядом с кодом (корень — src/lib.zig), сквозные — в test/.
    const unit = b.addTest(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = .Debug, .single_threaded = true });
    if (windows) unit.linkSystemLibrary("ws2_32");
    gen.addTo(unit.root_module);
    const lib = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = .Debug, .single_threaded = true });
    gen.addTo(lib);
    const e2e = b.addTest(.{ .root_source_file = b.path("test/all.zig"), .target = target, .optimize = .Debug, .single_threaded = true });
    e2e.root_module.addImport("clipper", lib);
    if (windows) e2e.linkSystemLibrary("ws2_32");
    const test_step = b.step("test", "модульные и сквозные тесты");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&b.addRunArtifact(e2e).step);

    // Замер нагрузки: инструмент под машину сборки (потоки), сервер — отдельно.
    const load = b.addExecutable(.{ .name = "load", .root_source_file = b.path("tools/load.zig"), .target = b.graph.host, .optimize = .ReleaseFast });
    const run_load = b.addRunArtifact(load);
    if (b.args) |args| run_load.addArgs(args);
    b.step("load", "замер нагрузки: zig build load -- HOST PORT [-c N] [-n N] [--close] ПУТЬ...").dependOn(&run_load.step);

    // Ключи перевода: обход src/ и запись каталогов (в дерево исходников, поэтому отдельным шагом).
    const t9n = b.addExecutable(.{ .name = "t9n", .root_source_file = b.path("tools/t9n.zig"), .target = b.graph.host });
    const run_t9n = b.addRunArtifact(t9n);
    run_t9n.addArgs(&.{ "extract", b.pathFromRoot("src"), b.pathFromRoot("src/t9n") });
    run_t9n.has_side_effects = true;
    b.step("t9n", "собрать ключи перевода интерфейса в src/t9n/*.t9n").dependOn(&run_t9n.step);

    // Тестовая заготовка для node-тестов: в программе данных нет, их кладёт этот шаг.
    const host_lib = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = b.graph.host, .optimize = .Debug, .single_threaded = true });
    if (b.graph.host.result.os.tag == .windows) host_lib.linkSystemLibrary("ws2_32", .{});
    gen.addTo(host_lib);
    const fixture_mod = b.createModule(.{ .root_source_file = b.path("test/fixture.zig") });
    fixture_mod.addImport("clipper", host_lib);
    const fixture = b.addExecutable(.{ .name = "fixture", .root_source_file = b.path("tools/fixture.zig"), .target = b.graph.host, .single_threaded = true });
    fixture.root_module.addImport("fixture", fixture_mod);
    if (b.graph.host.result.os.tag == .windows) fixture.linkSystemLibrary("ws2_32");
    const run_fixture = b.addRunArtifact(fixture);
    if (b.args) |args| run_fixture.addArgs(args);
    b.step("fixture", "тестовая заготовка в папку библиотеки: zig build fixture -- ПАПКА [-btree]").dependOn(&run_fixture.step);
}

/// Сервер под цель: исполняемый файл и путь к готовому бинарнику. Для Windows
/// до Vista бинарник проходит через pe-version: компоновщик пишет в заголовок PE
/// версию 6.0, и XP такой файл не запустит.
fn server(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gen: Generated) struct { *std.Build.Step.Compile, std.Build.LazyPath } {
    const windows = target.result.os.tag == .windows;
    const exe = b.addExecutable(.{
        .name = "clipper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Один цикл событий; мьютексы Zig тянут SRW-блокировки, которых нет в XP.
        .single_threaded = true,
    });
    if (windows) exe.linkSystemLibrary("ws2_32");
    gen.addTo(exe.root_module);
    const before_vista = windows and
        @intFromEnum(target.result.os.version_range.windows.min) < @intFromEnum(std.Target.Os.WindowsVersion.vista);
    if (!before_vista) return .{ exe, exe.getEmittedBin() };
    const pe = b.addExecutable(.{ .name = "pe-version", .root_source_file = b.path("src/pe_version.zig"), .target = b.graph.host });
    const patch = b.addRunArtifact(pe);
    patch.addFileArg(exe.getEmittedBin());
    return .{ exe, patch.addOutputFileArg("clipper.exe") };
}

/// Только языки, чьи буквы есть в windows-1251 (кодировка страниц и снимка).
const Lang = enum { ru, en };

/// Три модуля, которые делает сборка: `config` (язык, какие книги встроены),
/// `books` (встроенные книги в windows-1251) и `t9n_table` (пары «русская строка — перевод»).
const Generated = struct {
    config: *std.Build.Module,
    books: *std.Build.Module,
    table: *std.Build.Module,

    fn addTo(g: Generated, m: *std.Build.Module) void {
        m.addImport("config", g.config);
        m.addImport("books", g.books);
        m.addImport("t9n_table", g.table);
    }
};

fn exists(b: *std.Build, sub: []const u8) bool {
    b.build_root.handle.access(sub, .{}) catch return false;
    return true;
}

/// Файлы книг в папке: «<книга>x...md»; `want` решает, какие номера брать.
fn bookFiles(b: *std.Build, dir: []const u8, book0: bool, books: bool) std.ArrayList([]const u8) {
    var names = std.ArrayList([]const u8).init(b.allocator);
    var d = b.build_root.handle.openDir(dir, .{ .iterate = true }) catch return names;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".md")) continue;
        const x = std.mem.indexOfScalar(u8, e.name, 'x') orelse continue;
        const n = std.fmt.parseInt(u31, e.name[0..x], 10) catch continue;
        if (n > 2) {
            std.debug.print("{s}/{s}: встроенных книг три — 0, 1 и 2; файл пропущен\n", .{ dir, e.name });
            continue;
        }
        if ((n == 0 and book0) or (n > 0 and books)) names.append(b.fmt("{s}/{s}", .{ dir, e.name })) catch @panic("OOM");
    }
    return names;
}

const Formats = struct { pdf: bool, djvu: bool, voice: bool = true, ogg: bool = true, m4a: bool = false };

fn generated(b: *std.Build, lang: Lang, book0: bool, books: bool, zstd: bool, fmt: Formats) Generated {
    const empty_table = "pub const pairs = [_]struct { []const u8, []const u8 }{};\n";
    const stubs = b.addWriteFiles();
    const stub_table = stubs.add("t9n_table.zig", empty_table);
    const stub_books = stubs.add("books.zig", "pub const Chapter = struct { title: []const u8, text: []const u8 };\n" ++
        "pub const Book = struct { id: i32, title: []const u8, year: []const u8, annotation: []const u8, chapters: []const Chapter };\n" ++
        "pub const list = [_]Book{};\n");

    const options = b.addOptions();
    options.addOption(Lang, "lang", lang);
    options.addOption(bool, "book0", book0);
    options.addOption(bool, "books", books);
    options.addOption(bool, "zstd", zstd);
    options.addOption(bool, "pdf", fmt.pdf);
    options.addOption(bool, "djvu", fmt.djvu);
    options.addOption(bool, "voice", fmt.voice);
    options.addOption(bool, "ogg", fmt.ogg);
    options.addOption(bool, "m4a", fmt.m4a);

    // Инструменты сборки перекодируют тем же src/cp1251.zig, что и сервер.
    const cp = b.createModule(.{ .root_source_file = b.path("src/cp1251.zig"), .target = b.graph.host });
    cp.addAnonymousImport("t9n_table", .{ .root_source_file = stub_table });

    // Каталог интерфейса: русский — язык исходников, ему каталог не нужен.
    var table = stub_table;
    if (lang != .ru) {
        const catalog = b.fmt("src/t9n/{s}.t9n", .{@tagName(lang)});
        if (exists(b, catalog)) {
            const tool = b.addExecutable(.{ .name = "t9n", .root_source_file = b.path("tools/t9n.zig"), .target = b.graph.host });
            const run = b.addRunArtifact(tool);
            run.addArg("compile");
            run.addFileArg(b.path(catalog));
            table = run.addOutputFileArg("t9n_table.zig");
        } else std.debug.print("-Dlang={s}: нет {s} — интерфейс остаётся русским\n", .{ @tagName(lang), catalog });
    }

    // Встроенные книги: src/books/ru/ — русские, src/books/ — английские.
    var out = stub_books;
    if (book0 or books) {
        const dir = if (lang == .ru) "src/books/ru" else "src/books";
        var names = bookFiles(b, dir, book0, books);
        if (names.items.len == 0 and lang != .ru) {
            std.debug.print("-Dlang={s}: в {s} нет книг — встраиваются русские\n", .{ @tagName(lang), dir });
            names = bookFiles(b, "src/books/ru", book0, books);
        }
        if (names.items.len > 0) {
            const tool = b.addExecutable(.{ .name = "books", .root_source_file = b.path("tools/books.zig"), .target = b.graph.host });
            tool.root_module.addImport("cp1251", cp);
            const run = b.addRunArtifact(tool);
            out = run.addOutputFileArg("books.zig");
            for (names.items) |n| run.addFileArg(b.path(n));
        }
    }

    return .{ .config = options.createModule(), .books = b.createModule(.{ .root_source_file = out }), .table = b.createModule(.{ .root_source_file = table }) };
}
