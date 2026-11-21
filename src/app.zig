//! Приложение: состояние сервера (хранилище записей, снимок каталога, кэши,
//! буферы) и контекст одного запроса. Вся память запроса — заранее
//! выделенные буферы: арена, буфер тела страницы и буфер готового ответа.

const std = @import("std");
const t9n = @import("t9n.zig");
const net = @import("net/net.zig");
const cp = @import("cp1251.zig");
const http = @import("http.zig");
const sys = @import("sys.zig");
const L = @import("ledger.zig");
const snapshot = @import("snapshot.zig");
const cache = @import("cache.zig");
const theme = @import("theme.zig");
const auth = @import("auth.zig");
const dbm = @import("db.zig");
const library = @import("library.zig");
const W = @import("out.zig").W;
const Reply = @import("net/server.zig").Reply;
const route = @import("route.zig");
const layout = @import("layout.zig");
const fed_mod = @import("fed.zig");
pub const sections = @import("sections.zig");

pub const Config = struct {
    port: u16 = 0,
    root: []const u8 = ".",
    theme: theme.Base = .flibusta,
    btree: bool = false,
    tls_cert: ?[]const u8 = null,
    tls_key: ?[]const u8 = null,
    /// Сколько процессов обслуживает сайт (-w). Больше одного — хранилище
    /// общее: перед чтением дочитывается чужое, запись идёт под блокировкой.
    workers: u32 = 1,
    /// Номер этого воркера с единицы; 0 — процесс один или это главный.
    worker: u32 = 0,
    /// Федерация (-fed): null — выключена; "" — FEDIVERSE.csv в папке
    /// библиотеки; "-" — он же, но без новых сайтов; иначе файл CSV или
    /// список сайтов через запятую (см. fed.zig).
    fed: ?[]const u8 = null,
    /// Вход встроенного администратора /u/0 (-l, -pwd, -phc). Это не способ
    /// управлять сайтом, а способ его настроить: завести своего администратора —
    /// участника с правами. Без пароля в /u/0 не войти; вход — только с этой машины.
    admin_login: []const u8 = "admin",
    admin_pass: ?[]const u8 = null,
    admin_phc: ?[]const u8 = null,
    /// Разделы: кому что можно (-M, -R, -G, -N; sections.zig).
    sec: sections.Rules = .{},
    /// -zstd [N|ПУТЬ]: кадры снимка сжимаются своим zstd со словарём из файла
    /// clipper<N>.zstd (есть только при -Dzstd=true; zfile.zig).
    zstd: snapshot.zfile.Spec = .off,
    /// -img ПАПКА: папка картинок (книг — img/b/, досок — сама папка). Без флага —
    /// ROOTDIR/img. Нет папки — создаётся.
    img: ?[]const u8 = null,
    /// -pdf, -djvu: разрешить загрузку экспериментальных форматов (если разбор
    /// собран, -Dpdf / -Ddjvu). Без флага формат не принимается никем, что бы ни
    /// сказала панель: разбор нагружает только загрузку, хранится текст.
    pdf: bool = false,
    djvu: bool = false,

    /// Режим оформления по умолчанию (-d): auto — по устройству, light, dark, time — по часам.
    mode: theme.Mode = .auto,
    /// Главный (-c) и фирменный (-b) цвета: палитры тем пересчитываются от них (theme.setColors).
    core: ?theme.Rgb = null,
    brand: ?theme.Rgb = null,
    /// Свой значок (-ico, файл .ico) и логотип (-png, файл .png) вместо встроенных.
    ico: ?[]const u8 = null,
    png: ?[]const u8 = null,
    /// Адрес сайта (-s) — им подписана тема proza; UTF-8.
    site: []const u8 = "clipper.localhost",
    /// Название сайта (-n) — в заголовках и шапках; UTF-8.
    name: []const u8 = t9n.tr("Клиппер"),

    /// Форматы, которые вообще можно загружать при этом запуске: PDF и DjVu — только с -pdf / -djvu.
    pub fn launchFormats(cfg: Config) u8 {
        const import = @import("import.zig");
        var m: u8 = auth.Formats.all;
        if (!(import.has_pdf and cfg.pdf)) m &= ~(@as(u8, 1) << @intFromEnum(import.Kind.pdf));
        if (!(import.has_djvu and cfg.djvu)) m &= ~(@as(u8, 1) << @intFromEnum(import.Kind.djvu));
        return m;
    }

    /// Папка картинок: -img или ROOTDIR/img; нет — создаётся.
    pub fn openImg(cfg: Config, root: std.fs.Dir) !std.fs.Dir {
        return if (cfg.img) |p| std.fs.cwd().makeOpenPath(p, .{ .iterate = true }) else root.makeOpenPath("img", .{ .iterate = true });
    }

    pub fn codec(cfg: Config) snapshot.Codec {
        return if (cfg.zstd == .off) .deflate else .zstd;
    }
};

const arena_bytes = 24 << 20;
const body_bytes = 6 << 20;
const out_bytes = 8 << 20;
const frame_cache_bytes = 32 << 20;
const page_cache_bytes = 48 << 20;

pub const html_type = "text/html; charset=windows-1251";

/// Кэш готовых страниц для гостей. Ключ — хост, путь с параметрами и версия
/// (полная или мобильная); сброс — по поколению снимка, счётчику изменений
/// хранилища и смене суток. Токен CSRF в теле — заполнитель: его места
/// записаны и при выдаче заполняются токеном посетителя.
const PageCache = struct {
    const Entry = struct { body: []u8, csrf_at: [32]u32, csrf_n: u8 };

    map: std.StringHashMapUnmanaged(Entry) = .{},
    bytes: usize = 0,
    stamp: [3]u64 = .{ 0, 0, 0 },
    hits: u64 = 0,
    misses: u64 = 0,

    fn clear(pc: *PageCache, gpa: std.mem.Allocator) void {
        var it = pc.map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.body);
        }
        pc.map.clearRetainingCapacity();
        pc.bytes = 0;
    }

    fn check(pc: *PageCache, gpa: std.mem.Allocator, stamp: [3]u64) void {
        if (!std.mem.eql(u64, &pc.stamp, &stamp)) {
            pc.clear(gpa);
            pc.stamp = stamp;
        }
    }

    fn put(pc: *PageCache, gpa: std.mem.Allocator, key: []const u8, w: *const W) void {
        if (w.csrf_many or w.n > 512 * 1024) return;
        if (pc.bytes + w.n + key.len > page_cache_bytes) pc.clear(gpa);
        const k = gpa.dupe(u8, key) catch return;
        const body = gpa.dupe(u8, w.out()) catch {
            gpa.free(k);
            return;
        };
        const gop = pc.map.getOrPut(gpa, k) catch {
            gpa.free(k);
            gpa.free(body);
            return;
        };
        if (gop.found_existing) {
            gpa.free(k);
            pc.bytes -= gop.value_ptr.body.len;
            gpa.free(gop.value_ptr.body);
        } else pc.bytes += k.len;
        gop.value_ptr.* = .{ .body = body, .csrf_at = w.csrf_at, .csrf_n = w.csrf_n };
        pc.bytes += body.len;
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    /// Название и адрес сайта в windows-1251 (cfg.name, cfg.site); при выводе экранируются.
    name: []const u8 = "",
    site: []const u8 = "",
    root: std.fs.Dir,
    /// папка картинок (-img или ROOTDIR/img)
    img: std.fs.Dir,
    ledger: L.Ledger,
    snap: snapshot.Snapshot,
    snap_name: [64]u8 = undefined,
    snap_name_len: usize = 0,
    frames: cache.S3Fifo(snapshot.frame_max),
    /// файл словаря zstd (-zstd); его срез — snapshot.active
    zdict: ?snapshot.zfile.Loaded = null,
    pcache: PageCache = .{},
    arena_buf: []u8,
    body_buf: []u8,
    out_buf: []u8,
    admin: auth.Admin = .{},
    admin_store: [256]u8 = undefined,
    features: u16 = auth.all_features,
    features_at: u64 = 0,
    /// настройки панели: оформление и форматы загрузки (читаются вместе с функциями)
    look: theme.Look = .{},
    formats: auth.Formats = .{},
    fed: fed_mod.Fed = .{},
    views: u64 = 0,
    views_saved: u64 = 0,
    /// прочтения и скачивания, ещё не записанные в хранилище
    pending: std.AutoArrayHashMapUnmanaged(i32, [2]u32) = .{},
    now: i64 = 0,
    last_save: i64 = 0,
    last_purge: i64 = 0,
    rebuild_wanted: bool = false,

    /// Открывает библиотеку в папке `cfg.root`. Нет снимка — собирает его.
    pub fn init(gpa: std.mem.Allocator, cfg: Config, quiet: bool) !*App {
        var root = try std.fs.cwd().makeOpenPath(cfg.root, .{});
        errdefer root.close();
        inline for (.{ library.books_dir, "files", "tmp" }) |d| root.makePath(d) catch {};
        var img = try cfg.openImg(root);
        errdefer img.close();
        // незаконченные загрузки прошлого запуска (воркер их не трогает: рядом
        // могут идти загрузки соседей)
        if (cfg.worker != 0) {} else if (root.openDir("tmp", .{ .iterate = true })) |tmp_const| {
            var tmp = tmp_const;
            defer tmp.close();
            var it = tmp.iterate();
            while (it.next() catch null) |e| tmp.deleteFile(e.name) catch {};
        } else |_| {}

        var ledger = try L.Ledger.open(gpa, root, if (cfg.btree) .btree else .journal);
        errdefer ledger.close();
        var tmp_arena = std.heap.ArenaAllocator.init(gpa);
        defer tmp_arena.deinit();
        const ta = tmp_arena.allocator();

        const fresh = ledger.get(ta, "Kinit") == null;
        if (fresh) {
            ledger.put("Kinit", "1");
        }
        // словарь zstd (-zstd) — до отпечатка каталога: он в него входит
        const zdict = try snapshot.useDict(gpa, root, cfg.zstd);
        errdefer if (zdict) |z| {
            z.deinit(gpa);
            snapshot.active = .{};
        };
        var name_buf: [64]u8 = undefined;
        var mark: [16]u8 = undefined;
        const books_changed = cfg.worker == 0 and !std.mem.eql(u8, ledger.get(ta, "Kbooks") orelse "", library.booksMark(&mark, cfg.codec()));
        if (snapshot.current(root, &name_buf) == null or books_changed) {
            const st = try library.build(gpa, root, img, &ledger, cfg.codec(), !quiet);
            if (!quiet) std.debug.print(t9n.tr("[clipper] собран снимок каталога: книг {d}, файлов из books/ {d}\n"), .{ st.books, st.files });
        }
        const name = snapshot.current(root, &name_buf) orelse return error.NoSnapshot;
        var snap = try snapshot.Snapshot.open(root, name);
        errdefer snap.close();

        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{
            .gpa = gpa,
            .cfg = cfg,
            .root = root,
            .img = img,
            .ledger = ledger,
            .snap = snap,
            .zdict = zdict,
            .frames = try cache.S3Fifo(snapshot.frame_max).init(gpa, frame_cache_bytes),
            .arena_buf = try gpa.alloc(u8, arena_bytes),
            .body_buf = try gpa.alloc(u8, body_bytes),
            .out_buf = try gpa.alloc(u8, out_bytes),
        };
        @memcpy(app.snap_name[0..name.len], name);
        app.snap_name_len = name.len;
        app.now = sys.now();
        app.fed = try fed_mod.Fed.open(gpa, root, cfg.fed);
        errdefer app.fed.deinit();
        app.look.base = cfg.theme;
        app.name = try cp.encodeAlloc(gpa, cfg.name);
        errdefer gpa.free(app.name);
        app.site = try cp.encodeAlloc(gpa, cfg.site);
        errdefer gpa.free(app.site);

        const d = dbm.Db{ .l = &app.ledger, .s = &app.snap, .a = ta };
        if (d.user(0) == null) d.putUser(.{ .id = 0, .nick = "admin", .joined = "2002-09-01", .about = cp.text("Встроенный администратор сайта. Управляет всем через /panel."), .login = "" });
        app.views = @intCast(@max(0, std.fmt.parseInt(i64, d.setting("views") orelse "0", 10) catch 0));
        app.views_saved = app.views;
        try app.ledger.flush();
        return app;
    }

    pub fn deinit(app: *App) void {
        app.saveCounters();
        app.ledger.flush() catch {};
        app.pcache.clear(app.gpa);
        app.pcache.map.deinit(app.gpa);
        app.pending.deinit(app.gpa);
        app.fed.deinit();
        app.frames.deinit(app.gpa);
        app.gpa.free(app.name);
        app.gpa.free(app.site);
        app.gpa.free(app.arena_buf);
        app.gpa.free(app.body_buf);
        app.gpa.free(app.out_buf);
        app.snap.close();
        if (app.zdict) |z| {
            z.deinit(app.gpa);
            snapshot.active = .{};
        }
        app.ledger.close();
        app.img.close();
        app.root.close();
        app.gpa.destroy(app);
    }

    /// Вход /u/0 — из флагов запуска (-l, -pwd, -phc). Пароля нет — хеш пуст, и
    /// войти нельзя. В хранилище вход не пишется и в панели не меняется.
    pub fn loadAdmin(app: *App) void {
        var tmp_arena = std.heap.ArenaAllocator.init(app.gpa);
        defer tmp_arena.deinit();
        const ta = tmp_arena.allocator();
        const hash = if (app.cfg.admin_phc) |phc| phc else if (app.cfg.admin_pass) |p| auth.hashPassword(ta, p) else "";
        app.setAdmin(.{ .login = app.cfg.admin_login, .hash = hash });
    }

    pub fn setAdmin(app: *App, adm: auth.Admin) void {
        const login_n = @min(adm.login.len, 40);
        const hash_n = @min(adm.hash.len, app.admin_store.len - 40);
        @memcpy(app.admin_store[0..login_n], adm.login[0..login_n]);
        @memcpy(app.admin_store[40..][0..hash_n], adm.hash[0..hash_n]);
        app.admin = .{ .login = app.admin_store[0..login_n], .hash = app.admin_store[40..][0..hash_n] };
    }

    /// Настройки панели из хранилища: функции сайта, оформление, форматы
    /// загрузки. Перечитываются, когда хранилище менялось (или `force`).
    pub fn loadSettings(app: *App, a: std.mem.Allocator, force: bool) void {
        if (!force and app.features_at == app.ledger.changes) return;
        app.features_at = app.ledger.changes;
        app.features = auth.all_features;
        if (app.ledger.get(a, "Kfeatures")) |v| app.features = (std.fmt.parseInt(u16, v, 10) catch auth.all_features) & auth.all_features;
        // оформление: тема (пусто — флаг -t), режим, разрешённые темы и режимы, видна ли настройка
        app.look = .{ .base = app.cfg.theme, .mode = app.cfg.mode };
        if (app.ledger.get(a, "Klook")) |v| {
            if (theme.baseOf(L.field(v, 0))) |b| app.look.base = b;
            app.look.mode = std.meta.stringToEnum(theme.Mode, L.field(v, 1)) orelse .auto;
            app.look.bases = @intCast(L.fieldInt(v, 2) & 15);
            app.look.modes = @intCast(L.fieldInt(v, 3) & 15);
            app.look.show = L.fieldInt(v, 4) != 0;
        }
        app.formats = .{};
        if (app.ledger.get(a, "Kimport")) |v| app.formats = .{ .staff = @intCast(L.fieldInt(v, 0) & auth.Formats.all), .users = @intCast(L.fieldInt(v, 1) & auth.Formats.all) };
    }

    pub fn countRead(app: *App, book: i32, download: bool) void {
        const gop = app.pending.getOrPut(app.gpa, book) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0 };
        gop.value_ptr[if (download) 1 else 0] += 1;
    }

    /// Счётчики книги вместе с ещё не записанными.
    pub fn stat(app: *App, d: dbm.Db, book: i32) dbm.BookStat {
        var st = d.bookStat(book);
        if (app.pending.get(book)) |p| {
            st.reads += p[0];
            st.downloads += p[1];
        }
        return st;
    }

    fn saveCounters(app: *App) void {
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const d = dbm.Db{ .l = &app.ledger, .s = &app.snap, .a = fba.allocator() };
        var it = app.pending.iterator();
        while (it.next()) |e| {
            fba.reset();
            var st = d.bookStat(e.key_ptr.*);
            st.reads += e.value_ptr[0];
            st.downloads += e.value_ptr[1];
            d.putBookStat(e.key_ptr.*, st, true);
        }
        app.pending.clearRetainingCapacity();
        if (app.views != app.views_saved) {
            // прибавка к записанному, а не свой итог: рядом считают другие воркеры
            fba.reset();
            const stored: u64 = @intCast(@max(0, std.fmt.parseInt(i64, app.ledger.get(fba.allocator(), "Kviews") orelse "0", 10) catch 0));
            app.views = @max(stored, app.views_saved) + (app.views - app.views_saved);
            var nb: [24]u8 = undefined;
            app.ledger.putQuiet("Kviews", std.fmt.bufPrint(&nb, "{d}", .{app.views}) catch unreachable);
            app.views_saved = app.views;
        }
    }

    /// Другой процесс изменил хранилище: обновить то, что живёт в памяти.
    fn sync(app: *App) void {
        if (!app.ledger.foreign) return;
        app.ledger.foreign = false;
        app.adoptSnapshot();
    }

    /// Раз в секунду: чужие записи, новый снимок, счётчики.
    pub fn tick(app: *App, now: i64) void {
        app.now = now;
        app.fed.reloadIfChanged(app.root);
        app.ledger.refresh();
        app.sync();
        app.adoptSnapshot();
        if (now - app.last_save >= 5) {
            app.last_save = now;
            const shared = app.cfg.workers > 1;
            if (shared) app.ledger.hold() catch return; // занято — счётчики подождут
            defer if (shared) app.ledger.release();
            app.sync();
            app.saveCounters();
            app.ledger.flush() catch {};
        }
    }

    /// `library.current` называет другой файл — отображаем его вместо прежнего.
    pub fn adoptSnapshot(app: *App) void {
        var name_buf: [64]u8 = undefined;
        const name = snapshot.current(app.root, &name_buf) orelse return;
        if (std.mem.eql(u8, name, app.snap_name[0..app.snap_name_len])) return;
        const fresh = snapshot.Snapshot.open(app.root, name) catch |err| {
            std.debug.print(t9n.tr("[clipper] новый снимок {s} не открывается: {s}\n"), .{ name, @errorName(err) });
            return;
        };
        // Ответы не держат срезов снимка (страница собирается в свой буфер),
        // поэтому прежний можно закрыть сразу.
        app.snap.close();
        app.snap = fresh;
        @memcpy(app.snap_name[0..name.len], name);
        app.snap_name_len = name.len;
        app.frames.clear();
        app.pcache.clear(app.gpa);
    }

    /// Пересобирает снимок (после выкладывания книги, переноса черновика).
    pub fn rebuild(app: *App) !void {
        _ = try library.build(app.gpa, app.root, app.img, &app.ledger, app.cfg.codec(), false);
        app.adoptSnapshot();
    }

    /// Текст страницы чтения `k` (с нуля) книги: кадры из кэша или из снимка.
    pub fn pageText(app: *App, a: std.mem.Allocator, b: *const snapshot.Book, k: usize) ![]const u8 {
        const pg = app.snap.bookPages(b)[k];
        const out = try a.alloc(u8, pg.len);
        var at: usize = 0;
        var i: u32 = pg.first_frame;
        while (i < pg.first_frame + pg.n_frames) : (i += 1) {
            const key = (@as(u64, app.snap.h.gen) << 32) | i;
            const bytes = app.frames.get(key) orelse blk: {
                var tmp: [snapshot.frame_max]u8 = undefined;
                const raw = try app.snap.frame(i, &tmp);
                const slot = app.frames.put(key, raw.len);
                @memcpy(slot, raw);
                break :blk slot;
            };
            if (at + bytes.len > out.len) return error.Damaged;
            @memcpy(out[at..][0..bytes.len], bytes);
            at += bytes.len;
        }
        return out[0..at];
    }

    // ───────────── запрос ─────────────

    /// Гость и GET: готовая страница из кэша. true — ответ уже заполнен.
    /// Иначе запоминает ключ, под которым страницу стоит сохранить.
    pub fn cacheLookup(app: *App, c: *Ctx) bool {
        if (c.me != null or c.req.method == .POST) return false;
        app.pcache.check(app.gpa, .{ app.snap.h.gen, app.ledger.changes, @intCast(@divFloor(app.now, 86400)) });
        const key = std.fmt.allocPrint(c.a, "{s}\x00{s}\x00{d}{d}", .{ c.req.host, c.req.target, @intFromBool(c.mobile), @intFromBool(c.tls) }) catch return false;
        c.cache_key = key;
        const e = app.pcache.map.get(key) orelse {
            app.pcache.misses += 1;
            return false;
        };
        app.pcache.hits += 1;
        const body = app.out_buf[0..e.body.len];
        @memcpy(body, e.body);
        for (e.csrf_at[0..e.csrf_n]) |at| @memcpy(body[at..][0..32], &c.csrf);
        c.reply.status = 200;
        c.reply.ctype = html_type;
        c.reply.body = body;
        return true;
    }

    pub fn bodyLimit(app: *App, req: *const http.Request) u64 {
        var seg: [5][]const u8 = undefined;
        const n = splitPath(req.path, &seg);
        const voice_up = n == 2 and std.mem.eql(u8, seg[0], "v") and std.mem.eql(u8, seg[1], "new");
        if (voice_up or (n == 2 and std.mem.eql(u8, seg[0], "b") and std.mem.eql(u8, seg[1], "upload"))) {
            const big: u64 = if (voice_up) http.limits.voice_body else http.limits.upload_body;
            // право выкладывать проверяется до чтения тела; сеанс мог начать сосед
            if (app.cfg.workers > 1) {
                app.ledger.refresh();
                app.sync();
            }
            var buf: [8192]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const d = dbm.Db{ .l = &app.ledger, .s = &app.snap, .a = fba.allocator() };
            const sid = http.cookie(req.cookie, "sid") orelse return http.limits.form_body;
            const s = auth.session(d, sid, app.now) orelse return http.limits.form_body;
            if (std.mem.eql(u8, s.login, app.admin.login)) return big;
            const acc = d.account(s.login) orelse return http.limits.form_body;
            if (acc.blocked or acc.rights & (dbm.rights.upload | dbm.rights.staff) == 0) return http.limits.form_body;
            return big;
        }
        if (n == 3 and std.mem.eql(u8, seg[0], "f") and std.mem.eql(u8, seg[2], "post")) return http.limits.picture_body;
        return http.limits.form_body;
    }

    pub fn handle(app: *App, req: *const http.Request, body: []const u8, ip: net.Ip, tls_on: bool, reply: *Reply) void {
        // Несколько воркеров: чтение видит всё записанное соседями, запись
        // целиком (до пересборки снимка включительно) идёт под блокировкой.
        var held = false;
        if (app.cfg.workers > 1) {
            // вход через федерацию пишет и по GET: билет гасится, гость заводится
            if (req.method == .POST or std.mem.startsWith(u8, req.path, "/fed/")) {
                app.ledger.hold() catch {
                    reply.* = .{ .status = 503, .ctype = "text/plain; charset=utf-8", .body = t9n.tr("503: хранилище занято, повторите запрос") };
                    return;
                };
                held = true;
            } else app.ledger.refresh();
            app.sync();
            // список федерации мог только что дополнить или поправить сосед
            if (std.mem.startsWith(u8, req.path, "/fed") or std.mem.startsWith(u8, req.path, "/panel")) app.fed.reloadIfChanged(app.root);
        }
        defer if (held) app.ledger.release();
        var fba = std.heap.FixedBufferAllocator.init(app.arena_buf);
        const a = fba.allocator();
        var c = Ctx{
            .app = app,
            .a = a,
            .db = .{ .l = &app.ledger, .s = &app.snap, .a = a },
            .req = req,
            .reply = reply,
            .w = W.init(app.body_buf),
            .out = W.init(app.out_buf),
            .ip = ip,
            .tls = tls_on,
            .body = body,
        };
        app.loadSettings(a, false);
        c.begin();
        route.dispatch(&c);
        if (c.w.over or c.out.over or fba.end_index + 64 > app.arena_buf.len and reply.body.len == 0) {
            c.reply.* = .{ .status = 500, .ctype = "text/plain; charset=utf-8", .body = t9n.tr("500: страница не поместилась в буферы сервера") };
        }
        app.ledger.flush() catch {
            c.reply.* = .{ .status = 500, .ctype = "text/plain; charset=utf-8", .body = t9n.tr("500: запись не сохранена (ошибка хранилища)") };
        };
        if (app.rebuild_wanted) {
            app.rebuild_wanted = false;
            app.rebuild() catch |err| std.debug.print(t9n.tr("[clipper] снимок не пересобран: {s}\n"), .{@errorName(err)});
        }
        if (c.new_csrf and std.mem.startsWith(u8, reply.ctype, "text/html")) {
            reply.header("Set-Cookie: csrf={s}; Path=/; HttpOnly; SameSite=Lax", .{c.csrf});
        }
    }
};

pub fn splitPath(path_in: []const u8, seg: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path_in, '/');
    while (it.next()) |s| {
        if (n == seg.len) return seg.len + 1;
        seg[n] = s;
        n += 1;
    }
    return n;
}

pub const Crumb = struct { text: []const u8, href: []const u8 = "" };
pub const PageOpts = struct {
    title: []const u8,
    crumbs: []const Crumb = &.{},
    sec: []const u8 = "",
    /// «Оглавление» и подобное в боковой колонке: заголовок и готовая разметка.
    side_head: []const u8 = "",
    side: []const u8 = "",
};

pub const Ctx = struct {
    app: *App,
    a: std.mem.Allocator,
    db: dbm.Db,
    req: *const http.Request,
    reply: *Reply,
    /// тело страницы
    w: W,
    /// готовый ответ
    out: W,
    ip: net.Ip,
    tls: bool,
    body: []const u8,
    seg_buf: [6][]const u8 = undefined,
    seg: []const []const u8 = &.{},
    t_raw: []const u8 = "",
    m_raw: []const u8 = "",
    mobile: bool = false,
    th: theme.Theme = .{ .base = .flibusta, .mode = .auto },
    tm_plain: []const u8 = "",
    me: ?dbm.Account = null,
    session_key: []const u8 = "",
    csrf: [32]u8 = undefined,
    new_csrf: bool = false,
    form: http.Form = .{},
    status: u16 = 200,
    no_cache: bool = false,
    cache_key: []const u8 = "",

    fn begin(c: *Ctx) void {
        var path = c.req.path;
        while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        const n = splitPath(path, &c.seg_buf);
        c.seg = if (n > c.seg_buf.len) &.{ "", "", "", "", "", "", "" } else c.seg_buf[0..n];

        if (http.cookie(c.req.cookie, "csrf")) |tok| {
            if (auth.validToken(tok)) @memcpy(&c.csrf, tok) else c.new_csrf = true;
        } else c.new_csrf = true;
        if (c.new_csrf) auth.randomToken(&c.csrf);

        me: {
            const sid = http.cookie(c.req.cookie, "sid") orelse break :me;
            if (auth.session(c.db, sid, c.app.now)) |s| {
                if (std.mem.eql(u8, s.login, c.app.admin.login)) {
                    // /u/0 — только с этой машины: сеанс, открытый отсюда, снаружи не действует
                    if (!c.isLocal()) break :me;
                    c.me = .{ .login = c.app.admin.login, .user = 0, .hash = c.app.admin.hash, .rights = dbm.rights.all, .blocked = false };
                } else if (c.db.account(s.login)) |acc| {
                    if (!acc.blocked) c.me = acc;
                }
                if (c.me != null) c.session_key = s.key;
            }
        }
        c.t_raw = c.q("t");
        c.m_raw = c.q("m");
        c.setTm();
    }

    /// Пересчитывает всё, что зависит от `t` и `m`.
    pub fn setTm(c: *Ctx) void {
        const ua = c.req.user_agent;
        c.mobile = if (std.mem.eql(u8, c.m_raw, "true")) true else if (std.mem.eql(u8, c.m_raw, "false")) false else blk: {
            inline for (.{ "Mobi", "Android", "iPhone", "Opera Mini", "Windows CE", "Symbian", "J2ME" }) |k| {
                if (std.ascii.indexOfIgnoreCase(ua, k) != null) break :blk true;
            }
            break :blk false;
        };
        c.th = theme.pick(c.t_raw, c.app.look);
        var buf = c.a.alloc(u8, (c.t_raw.len + c.m_raw.len) * 3 + 16) catch return;
        var w = W.init(buf);
        if (c.m_raw.len > 0) {
            w.raw("m=");
            w.urlenc(c.m_raw);
        }
        if (c.t_raw.len > 0) {
            if (w.n > 0) w.byte('&');
            w.raw("t=");
            w.urlenc(c.t_raw);
        }
        c.tm_plain = buf[0..w.n];
        buf = c.a.alloc(u8, w.n + 8) catch return;
        var wh = W.init(buf);
        if (std.mem.indexOfScalar(u8, c.tm_plain, '&')) |amp| {
            wh.raw(c.tm_plain[0..amp]);
            wh.raw("&amp;");
            wh.raw(c.tm_plain[amp + 1 ..]);
        } else wh.raw(c.tm_plain);
        c.w.tm = buf[0..wh.n];
        c.out.tm = c.w.tm;
    }

    /// Параметр адреса; нет — пустая строка.
    pub fn q(c: *Ctx, name: []const u8) []const u8 {
        return http.param(c.a, c.req.query, name) orelse "";
    }

    pub fn qInt(c: *Ctx, name: []const u8) i64 {
        return std.fmt.parseInt(i64, std.mem.trim(u8, c.q(name), " "), 10) catch 0;
    }

    /// Посетитель за этой же машиной: соединение с loopback и не через обратный прокси
    /// (за NGINX на той же машине все соединения — с 127.0.0.1).
    pub fn isLocal(c: *const Ctx) bool {
        return net.isLoopback(c.ip) and !c.req.proxied;
    }

    pub fn isRoot(c: *const Ctx) bool {
        return if (c.me) |m| m.user == 0 else false;
    }

    /// Модератор: право «сотрудник» или /u/0.
    pub fn isModerator(c: *const Ctx) bool {
        const me = c.me orelse return false;
        return me.user == 0 or me.rights & dbm.rights.staff != 0;
    }

    /// Раздел, к которому относится функция панели (null — функция общая).
    pub fn sectionOf(f: auth.Feature) ?sections.Sec {
        return switch (f) {
            .poems => .p,
            .books, .upload, .comments, .downloads => .b,
            .drafts => .d,
            .forum, .boards => .f,
            .quotes => .q,
            else => null,
        };
    }

    /// Раздел виден этому посетителю: в меню, списках, поиске, на главной.
    pub fn secListed(c: *const Ctx, s: sections.Sec) bool {
        const r = c.app.cfg.sec;
        if (sections.Rules.has(r.off, s)) return false;
        return c.me != null or r.guestOk(s);
    }

    /// Виден ли посетителю раздел, которому принадлежит адрес ("/b/3", "/c", "/x/p/…", "/e/f/1").
    /// Адрес не раздела — виден.
    pub fn pathListed(c: *const Ctx, path: []const u8) bool {
        var p = path;
        if (std.mem.startsWith(u8, p, "/e/") or std.mem.startsWith(u8, p, "/x/")) p = p[2..];
        if (std.mem.startsWith(u8, p, "/bookmarks")) return c.secListed(.b);
        if (p.len < 2 or p[0] != '/' or (p.len > 2 and p[2] != '/' and p[2] != '?' and p[2] != '#' and p[2] != '.')) return true;
        return switch (p[1]) {
            'p' => c.secListed(.p),
            'b', 'q' => c.secListed(.b),
            'd' => c.secListed(.d),
            'f' => c.secListed(.f),
            'c' => c.secListed(.q),
            'v' => c.secListed(.v),
            else => true,
        };
    }

    /// Раздел открывается по адресу (скрытые книги цитатника — тоже).
    pub fn secReadable(c: *const Ctx, s: sections.Sec) bool {
        const r = c.app.cfg.sec;
        return r.exists(s) and (c.me != null or r.guestOk(s));
    }

    pub fn secWritable(c: *const Ctx, s: sections.Sec) bool {
        return c.secReadable(s) and c.app.cfg.sec.writable(s, c.isModerator());
    }

    /// Флаги запуска для функции: выгрузка книг — запись, остальное — видимость.
    fn secAllows(c: *const Ctx, f: auth.Feature) bool {
        const s = sectionOf(f) orelse return true;
        return if (f == .upload) c.secWritable(s) else c.secListed(s);
    }

    pub fn featureOn(c: *const Ctx, f: auth.Feature) bool {
        return c.app.features & auth.bit(f) != 0 and c.secAllows(f);
    }

    /// Функция включена (или смотрит администратор, для которого панель не
    /// действует). Флаги запуска действуют и на администратора.
    pub fn featureOpen(c: *const Ctx, f: auth.Feature) bool {
        return (c.app.features & auth.bit(f) != 0 or c.isModerator()) and c.secAllows(f);
    }

    pub fn can(c: *const Ctx, right: u8, f: ?auth.Feature) bool {
        const me = c.me orelse return false;
        if (f) |ff| if (sectionOf(ff)) |s| if (!c.secWritable(s)) return false;
        // сотрудник может всё то же, что /u/0
        if (me.user == 0 or me.rights & dbm.rights.staff != 0) return true;
        return me.rights & right != 0 and (f == null or c.featureOn(f.?));
    }

    /// Форматы книг, которые посетитель вправе выкладывать (биты `import.Kind`).
    pub fn formats(c: *const Ctx) u8 {
        const me = c.me orelse return 0;
        const m: u8 = if (me.user == 0) auth.Formats.all else if (me.rights & dbm.rights.staff != 0) c.app.formats.staff else c.app.formats.users;
        return m & c.app.cfg.launchFormats();
    }

    pub fn today(c: *Ctx) []const u8 {
        const buf = c.a.create([10]u8) catch return "";
        return http.isoDate(buf, c.app.now);
    }

    /// Адрес текущей страницы с параметрами (для `back=`).
    pub fn here(c: *const Ctx) []const u8 {
        return c.req.target;
    }

    /// "http://host" — для кода встраивания.
    pub fn origin(c: *Ctx, w: *W) void {
        w.raw(if (c.tls) "https://" else "http://");
        w.esc(if (c.req.host.len > 0) c.req.host else "localhost");
    }

    // ───────────── кусочки разметки ─────────────

    /// Скрытые поля `m` и `t`.
    pub fn hidden(c: *Ctx) void {
        if (c.m_raw.len > 0) c.w.f("<input type=\"hidden\" name=\"m\" value=\"{h}\">", .{c.m_raw});
        if (c.t_raw.len > 0) c.w.f("<input type=\"hidden\" name=\"t\" value=\"{h}\">", .{c.t_raw});
    }

    /// Скрытые поля формы POST: `m`, `t` и токен CSRF.
    pub fn post(c: *Ctx) void {
        c.hidden();
        c.w.raw("<input type=\"hidden\" name=\"_csrf\" value=\"");
        c.w.markCsrf(&c.csrf);
        c.w.raw("\">");
    }

    /// Ссылка на автора: участник — /u, человек или персонаж — /c.
    pub fn aLink(c: *Ctx, id: i32) void {
        // люди и персонажи живут в разделе цитат: без него имя — просто текст
        if (!c.db.isUser(id) and !c.secListed(.q)) return c.w.esc(c.db.name(id));
        c.w.f("<a href=\"{U}{s}{d}{E}\">{h}</a>", .{ if (c.db.isUser(id)) "/u/" else "/c/", id, c.db.name(id) });
    }

    /// Автор книги (встроенные книги — за администратором /u/0).
    pub fn bookAuthor(c: *Ctx, book_id: i32, author: i32) void {
        _ = book_id;
        c.aLink(author);
    }

    pub fn sign(c: *Ctx, n: i64) void {
        if (n < 0) c.w.f("<span class=\"neg\">{d}</span>", .{n}) else c.w.int(n);
    }

    pub fn msgBox(c: *Ctx, msg: []const u8) void {
        if (msg.len > 0) c.w.f("<div class=\"box\"><b>{h}</b></div>", .{msg});
    }

    // ───────────── ответы ─────────────

    /// Заворачивает тело (`c.w`) в оформление темы и делает его ответом.
    pub fn page(c: *Ctx, o: PageOpts) void {
        layout.page(c, o);
        c.reply.status = c.status;
        c.reply.ctype = html_type;
        c.reply.body = c.out.out();
        if (c.cache_key.len > 0 and !c.no_cache and c.status == 200 and !c.out.over) c.app.pcache.put(c.app.gpa, c.cache_key, &c.out);
    }

    pub fn notFound(c: *Ctx) void {
        c.fail(404, cp.text("Страница не найдена"));
    }

    pub fn denied(c: *Ctx, why: []const u8) void {
        c.fail(403, why);
    }

    /// Страница «404» макета с пояснением и нужным кодом ответа.
    pub fn fail(c: *Ctx, status: u16, why: []const u8) void {
        c.w.n = 0;
        c.w.csrf_n = 0;
        c.status = status;
        c.no_cache = true;
        c.w.f("<h2>404</h2><p>{h}</p><p><a href=\"{U}/{E}\">На главную</a> · <a href=\"{U}/help{E}\">Схема адресов</a></p>", .{why});
        c.page(.{ .title = "404", .crumbs = &.{.{ .text = "404" }} });
    }

    /// 303 на адрес сайта; `m` и `t` дописываются (перед `#…`).
    pub fn redirect(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [2600]u8 = undefined;
        var w = W.init(&buf);
        const raw = std.fmt.allocPrint(c.a, fmt, args) catch "/";
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        w.raw(raw[0..hash]);
        if (c.tm_plain.len > 0) {
            w.byte(if (std.mem.indexOfScalar(u8, raw[0..hash], '?') != null) '&' else '?');
            w.raw(c.tm_plain);
        }
        w.raw(raw[hash..]);
        const loc = if (w.over) "/" else w.out();
        for (loc) |ch| if (ch < 0x21 or ch == 0x7F) {
            c.reply.header("Location: /", .{});
            c.reply.status = 303;
            return;
        };
        c.reply.status = 303;
        c.reply.ctype = "text/plain; charset=utf-8";
        c.reply.body = "";
        c.reply.header("Location: {s}", .{loc});
    }

    /// Готовое тело не-HTML (или своя страница без оформления темы).
    pub fn send(c: *Ctx, ctype: []const u8, bytes: []const u8) void {
        c.reply.status = c.status;
        c.reply.ctype = ctype;
        c.reply.body = bytes;
    }

    /// Адрес для возврата: только путь этого сайта.
    pub fn safeBack(b: []const u8) []const u8 {
        if (b.len > 0 and b[0] == '/' and !(b.len > 1 and (b[1] == '/' or b[1] == '\\'))) return b;
        return "/";
    }
};
