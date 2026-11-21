//! Clipper — цифровая библиотека. Запуск: clipper -p PORT (см. cli.zig).

const std = @import("std");
const t9n = @import("t9n.zig");
const net = @import("net/net.zig");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const http = @import("http.zig");
const sys = @import("sys.zig");
const auth = @import("auth.zig");
const L = @import("ledger.zig");
const library = @import("library.zig");
const route = @import("route.zig");
const theme = @import("theme.zig");
const app_mod = @import("app.zig");
const server = @import("net/server.zig");
const tls = @import("net/tls.zig");
const workers = @import("workers.zig");
const import = @import("import.zig");
const cp1251 = @import("cp1251.zig");
const fed = @import("fed.zig");
const client = @import("net/client.zig");
const snapshot = @import("snapshot.zig");
const zfile = @import("zfile.zig");

extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) i32;

/// Одна понятная строка и ненулевой код выхода.
fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("clipper: " ++ t9n.tr(fmt) ++ "\n", args);
    std.process.exit(2);
}

fn handle(ctx: *anyopaque, req: *const http.Request, body: []const u8, ip: net.Ip, tls_on: bool, reply: *server.Reply) void {
    const app: *app_mod.App = @ptrCast(@alignCast(ctx));
    app.handle(req, body, ip, tls_on, reply);
}
fn bodyLimit(ctx: *anyopaque, req: *const http.Request) u64 {
    const app: *app_mod.App = @ptrCast(@alignCast(ctx));
    return app.bodyLimit(req);
}
fn tick(ctx: *anyopaque, now: i64) void {
    const app: *app_mod.App = @ptrCast(@alignCast(ctx));
    app.tick(now);
    if (parent) |p| if (workers.orphaned(p)) {
        app.deinit(); // счётчики — на диск
        std.process.exit(0);
    };
}

pub fn main() void {
    if (builtin.os.tag == .windows) _ = SetConsoleOutputCP(65001);
    const gpa = std.heap.page_allocator;
    const argv = std.process.argsAlloc(gpa) catch die(t9n.tr("не хватает памяти"), .{});
    var msg: []const u8 = "";
    const args = cli.parse(argv, &msg) catch die("{s}", .{msg});

    switch (args.command) {
        .help => {
            std.io.getStdOut().writeAll(cli.usage) catch {};
            return;
        },
        .hash => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            const h = auth.hashPassword(arena.allocator(), args.password);
            if (h.len == 0) die(t9n.tr("хеш не посчитан"), .{});
            std.io.getStdOut().writer().print("{s}\n", .{h}) catch {};
            return;
        },
        .build => return build(gpa, args),
        .convert => return convert(gpa, args.file),
        .fedcheck => return fedcheck(gpa, args.file),
        .zstd => return if (@import("config").zstd) zstdTrain(gpa, args) else unreachable,
        .serve => {},
    }

    var cfg = args.cfg;
    net.startup() catch die(t9n.tr("сеть недоступна (Winsock 2.2)"), .{});
    var tls_cfg: ?*const tls.Config = null;
    var lfd: net.Socket = net.invalid;
    var app: *app_mod.App = undefined;
    // Windows: главный запустил этот процесс воркером и передал ему сокет.
    var worker: ?workers.Worker = if (args.worker_spec) |spec| (workers.fromSpec(spec) orelse die(t9n.tr("--worker — служебный флаг: воркеров запускает сам clipper (-w N)"), .{})) else null;

    if (worker == null) {
        // Один процесс или главный: всё, что делается один раз и о чём стоит
        // сказать вслух, — первый снимок каталога, пароль администратора,
        // проверка ключа TLS, порт.
        app = openApp(gpa, cfg, false);
        if (cfg.tls_cert) |cert| tls_cfg = tls.Config.load(gpa, cert, cfg.tls_key.?, &msg) catch die("{s}", .{msg});
        lfd = net.listen(cfg.port) catch |err| switch (err) {
            error.AddressInUse => die(t9n.tr("порт {d} занят"), .{cfg.port}),
            else => die(t9n.tr("порт {d} не открывается: {s}"), .{ cfg.port, @errorName(err) }),
        };
        var wb: [40]u8 = undefined;
        std.debug.print(t9n.tr("clipper: {s}://localhost:{d} · библиотека {s} · книг {d} · тема {s} · записи: {s}{s}{s}\n"), .{
            if (tls_cfg != null) "https" else "http", cfg.port,                                                                                      cfg.root,
            app.snap.books.len,                        @tagName(cfg.theme),                                                                           if (cfg.btree) t9n.tr("B+ дерево") else t9n.tr("журнал"),
            if (cfg.workers > 1) (std.fmt.bufPrint(&wb, t9n.tr(" · воркеров {d}"), .{cfg.workers}) catch "") else "", if (app.admin.hash.len == 0) t9n.tr(" · вход /u/0 закрыт (нет -pwd или -phc)") else "",
        });
        if (app.fed.on()) std.debug.print(t9n.tr("clipper: федерация — {s}, сайтов {d}{s}\n"), .{
            switch (app.fed.mode) {
                .open => t9n.tr("новые сайты записываются в список"),
                .closed => t9n.tr("только сайты из списка"),
                else => t9n.tr("только сайты из флага -fed"),
            },
            app.fed.entries.items.len,
            if (app.fed.mode == .open and !app.fed.allowIn(null) and !app.fed.allowOut(null)) t9n.tr(" · новым сайтам вход закрыт, пока не разрешит строка localhost или /panel") else "",
        });
        if (cfg.workers > 1) {
            app.deinit(); // у каждого воркера свои файлы и своя память
            worker = workers.supervise(gpa, lfd, cfg.workers); // возвращается только в воркере (Linux)
        }
    }
    if (worker) |w| {
        cfg.worker = w.index;
        lfd = w.lfd;
        parent = w.parent;
        net.adopt(lfd) catch die(t9n.tr("воркер {d}: сокет главного процесса не унаследован"), .{w.index});
        app = openApp(gpa, cfg, true);
        if (tls_cfg == null) if (cfg.tls_cert) |cert| {
            tls_cfg = tls.Config.load(gpa, cert, cfg.tls_key.?, &msg) catch die("{s}", .{msg});
        };
    }

    var tmp_dir = app.root.openDir("tmp", .{}) catch |err| die(t9n.tr("папка tmp не открывается: {s}"), .{@errorName(err)});
    defer tmp_dir.close();
    var srv = server.Server.init(gpa, lfd, 1024, .{ .ctx = app, .handle = handle, .body_limit = bodyLimit, .tick = tick, .tmp_dir = tmp_dir }, tls_cfg) catch |err| die(t9n.tr("сервер не запущен: {s}"), .{@errorName(err)});
    if (worker) |w| srv.gate = w.gate;
    srv.run();
}

/// Главный процесс этого воркера (null — процесс один).
var parent: ?workers.Parent = null;

/// Файл значка или логотипа (-ico, -png): до 1 МБ и с правильным заголовком, иначе сервер не стартует.
fn loadArt(gpa: std.mem.Allocator, path: []const u8, png: bool) []const u8 {
    const flag = if (png) "-png" else "-ico";
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch |err| die(t9n.tr("{s} {s}: файл не читается или больше 1 МБ ({s})"), .{ flag, path, @errorName(err) });
    if (!route.artOk(png, bytes)) die(t9n.tr("{s} {s}: это не {s}"), .{ flag, path, if (png) "PNG" else t9n.tr("значок ICO") });
    return bytes;
}

fn openApp(gpa: std.mem.Allocator, cfg: app_mod.Config, quiet: bool) *app_mod.App {
    const app = app_mod.App.init(gpa, cfg, quiet) catch |err| switch (err) {
        error.Busy => die(t9n.tr("хранилище занято другим процессом"), .{}),
        error.Damaged => die(t9n.tr("снимок каталога или хранилище повреждены ({s})"), .{cfg.root}),
        error.BadFed => die("{s}", .{fed.problem()}),
        error.NoDict, error.BadDict => dictProblem(err, cfg.zstd),
        else => die(t9n.tr("папка библиотеки {s} не открывается: {s}"), .{ cfg.root, @errorName(err) }),
    };
    app.loadAdmin();
    theme.setColors(cfg.core, cfg.brand);
    if (cfg.ico) |p| route.own_ico = loadArt(gpa, p, false);
    if (cfg.png) |p| route.own_png = loadArt(gpa, p, true);
    theme.setAssetVersion(cfg.core, cfg.brand, route.own_ico, route.own_png);
    return app;
}

/// Словарь -zstd не найден или испорчен: что искали и как его сделать.
fn dictProblem(err: anyerror, spec: zfile.Spec) noreturn {
    if (err == error.BadDict) die(t9n.tr("{s}: испорченный словарь zstd (пересоздать: clipper zstd N)"), .{zfile.problem});
    if (err != error.NoDict) die(t9n.tr("словарь zstd не загружен: {s}"), .{@errorName(err)});
    switch (spec) {
        .path => |p| die(t9n.tr("{s}: файла словаря zstd нет"), .{p}),
        .kb => |n| die(t9n.tr("нет clipper{d}.zstd ни в текущей папке, ни в папке программы (создать: clipper zstd {d})"), .{ n, n }),
        else => die(t9n.tr("нет clipperN.zstd ни в текущей папке, ни в папке программы (создать: clipper zstd 16)"), .{}),
    }
}

/// clipper zstd N [-r ROOTDIR] [ПАПКА…]: обучает словарь для кадров N КБ на текстах
/// библиотеки (текущий снимок) или на книгах в папках и пишет clipper<N>.zstd сюда.
fn zstdTrain(gpa: std.mem.Allocator, args: cli.Args) void {
    const zdict = @import("zdict.zig");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t0 = sys.nowMs();
    var text = std.ArrayList(u8).init(a);
    var files: usize = 0;
    if (args.dirs.len == 0) {
        // тексты своей библиотеки: книги из снимка и стихи
        var root = std.fs.cwd().openDir(args.cfg.root, .{}) catch |err| die(t9n.tr("папка библиотеки {s} не открывается: {s}"), .{ args.cfg.root, @errorName(err) });
        defer root.close();
        const h = snapshot.currentHeader(root) orelse die(t9n.tr("в {s} нет снимка каталога: сначала clipper build или clipper -p PORT"), .{args.cfg.root});
        const zd = if (h.codec == @intFromEnum(snapshot.Codec.zstd)) (snapshot.useDict(gpa, root, .auto) catch |err| dictProblem(err, .auto)) else null;
        defer if (zd) |z| z.deinit(gpa);
        var name_buf: [64]u8 = undefined;
        var s = snapshot.Snapshot.open(root, snapshot.current(root, &name_buf).?) catch die(t9n.tr("снимок каталога или хранилище повреждены ({s})"), .{args.cfg.root});
        defer s.close();
        var buf: [snapshot.frame_max]u8 = undefined;
        for (0..s.frames.len) |i| text.appendSlice(s.frame(@intCast(i), &buf) catch continue) catch die(t9n.tr("не хватает памяти"), .{});
        for (s.pieces) |p| {
            text.appendSlice(s.str(p.text)) catch die(t9n.tr("не хватает памяти"), .{});
            text.appendSlice("\n\n") catch {};
        }
        files = s.books.len;
    } else for (args.dirs) |path| {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| die(t9n.tr("папка {s} не открывается: {s}"), .{ path, @errorName(err) });
        defer dir.close();
        var walk = dir.walk(a) catch die(t9n.tr("не хватает памяти"), .{});
        while (walk.next() catch null) |e| {
            if (e.kind != .file) continue;
            var ba = std.heap.ArenaAllocator.init(gpa);
            defer ba.deinit();
            const bytes = e.dir.readFileAlloc(ba.allocator(), e.basename, 512 << 20) catch continue;
            var budget = import.Budget{ .left = import.budget_bytes };
            const parsed = import.parse(ba.allocator(), import.detect(e.basename, bytes), bytes, &budget) catch continue;
            for (parsed.chapters) |ch| {
                text.appendSlice(ch.text) catch die(t9n.tr("не хватает памяти"), .{});
                text.appendSlice("\n\n") catch {};
            }
            files += 1;
        }
    }
    if (text.items.len < 4096) die(t9n.tr("для словаря мало текста: {d} байт (нужно хотя бы 4 КБ)"), .{text.items.len});
    // больше 64 МБ не нужно: берутся куски по 64 КБ равномерно по всему тексту
    const cap = 64 << 20;
    var corpus = text.items;
    if (corpus.len > cap) {
        const step = corpus.len / (cap / (64 << 10));
        var w: usize = 0;
        var r: usize = 0;
        while (r + (64 << 10) <= corpus.len and w + (64 << 10) <= cap) : (r += step) {
            std.mem.copyForwards(u8, corpus[w..][0 .. 64 << 10], corpus[r..][0 .. 64 << 10]);
            w += 64 << 10;
        }
        corpus = corpus[0..w];
    }
    const dict = zdict.train(a, corpus, .{}) catch die(t9n.tr("не хватает памяти"), .{});
    const bytes = zfile.encode(a, args.zstd_kb, dict) catch die(t9n.tr("не хватает памяти"), .{});
    var nb: [32]u8 = undefined;
    const name = zfile.fileName(&nb, args.zstd_kb);
    std.fs.cwd().writeFile(.{ .sub_path = name, .data = bytes }) catch |err| die(t9n.tr("{s} не записан: {s}"), .{ name, @errorName(err) });
    std.debug.print(t9n.tr("clipper zstd: {s} — кадр {d} КБ, словарь {d} КБ из {d} КБ текста (книг и файлов {d}), {d} мс\n"), .{ name, args.zstd_kb, dict.len / 1024, text.items.len / 1024, files, sys.nowMs() - t0 });
}

/// Разбирает один файл книги и печатает его канонический вид (UTF-8).
fn convert(gpa: std.mem.Allocator, path: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const bytes = std.fs.cwd().readFileAlloc(a, path, 512 << 20) catch |err| die(t9n.tr("{s}: не читается ({s})"), .{ path, @errorName(err) });
    var budget = import.Budget{ .left = import.budget_bytes };
    const t0 = sys.nowMs();
    const kind = import.detect(path, bytes);
    const parsed = import.parse(a, kind, bytes, &budget) catch |err| {
        var why: [400]u8 = undefined;
        die("{s}: {s}", .{ path, why[0..cp1251.toUtf8(&why, import.reason(err))] });
    };
    const text = import.canonical(a, parsed, 0) catch die(t9n.tr("не хватает памяти"), .{});
    var paras: usize = 0;
    for (parsed.chapters) |ch| paras += std.mem.count(u8, ch.text, "\n\n") + 1;
    std.debug.print(t9n.tr("clipper convert: {s} — {s}, глав {d}, абзацев {d}, {d} КБ текста, {d} мс\n"), .{ path, @tagName(kind), parsed.chapters.len, paras, text.len / 1024, sys.nowMs() - t0 });
    std.io.getStdOut().writeAll(text) catch {};
}

/// Спрашивает сайт так же, как при входе гостя: настоящий участник федерации
/// на несуществующий билет отвечает «clipper-fed 1 / error=ticket».
fn fedcheck(gpa: std.mem.Allocator, site: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var nb: [fed.max_domain]u8 = undefined;
    const name = fed.normalize(&nb, site) orelse die(t9n.tr("fedcheck: «{s}» — не имя сайта"), .{site});
    const https = fed.useHttps(name.scheme, name.domain);
    net.startup() catch die(t9n.tr("сеть недоступна (Winsock 2.2)"), .{});
    const t0 = sys.nowMs();
    const res = client.get(a, https, name.domain, "/fed/verify?ticket=00000000000000000000000000000000&for=fedcheck", false) catch |err| die("fedcheck: {s}://{s} — {s}", .{
        if (https) "https" else "http", name.domain, switch (err) {
            error.NoTls => t9n.tr("эта сборка (для Windows XP) не умеет https"),
            error.Tls => t9n.tr("сертификат https не принят или рукопожатие не удалось"),
            error.Timeout => t9n.tr("нет ответа за отведённое время"),
            error.Resolve, error.BadAddress => t9n.tr("имя не найдено"),
            error.Protocol => t9n.tr("ответ — не HTTP"),
            else => t9n.tr("соединение не установлено"),
        },
    });
    const yes = std.mem.startsWith(u8, res.body, "clipper-fed 1");
    std.debug.print(t9n.tr("clipper fedcheck: {s}://{s} — ответ {d} за {d} мс: {s}\n"), .{
        if (https) "https" else "http", name.domain, res.status, sys.nowMs() - t0,
        if (yes) t9n.tr("участник федерации Клиппер") else t9n.tr("не участник федерации (нет Клиппер или он запущен без -fed)"),
    });
    if (!yes) std.process.exit(1);
}

fn build(gpa: std.mem.Allocator, args: cli.Args) void {
    var root = std.fs.cwd().makeOpenPath(args.cfg.root, .{}) catch |err| die(t9n.tr("папка библиотеки {s} не открывается: {s}"), .{ args.cfg.root, @errorName(err) });
    defer root.close();
    root.makePath(library.books_dir) catch {};
    var ledger = L.Ledger.open(gpa, root, if (args.cfg.btree) .btree else .journal) catch |err| die(t9n.tr("хранилище не открывается: {s}"), .{@errorName(err)});
    defer ledger.close();
    var img = args.cfg.openImg(root) catch |err| die(t9n.tr("папка картинок не открывается: {s}"), .{@errorName(err)});
    defer img.close();
    const zd = snapshot.useDict(gpa, root, args.cfg.zstd) catch |err| dictProblem(err, args.cfg.zstd);
    defer if (zd) |z| z.deinit(gpa);
    const t0 = sys.nowMs();
    const st = library.build(gpa, root, img, &ledger, args.cfg.codec(), true) catch |err| die(t9n.tr("снимок не собран: {s}"), .{@errorName(err)});
    std.debug.print(t9n.tr("clipper build: library.{d}.snap — книг {d} (файлов {d}, пропущено {d}), текст {d} КБ → {d} КБ, {d} мс\n"), .{ st.gen, st.books, st.files, st.skipped, st.raw / 1024, st.packed_bytes / 1024, sys.nowMs() - t0 });
    if (st.images > 0 or st.images_failed > 0) std.debug.print(t9n.tr("clipper build: картинок {d} (обработано заново {d}, не разобрано {d})\n"), .{ st.images, st.images_new, st.images_failed });
}

test {
    _ = @import("lib.zig");
}
