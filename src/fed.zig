//! Федерация (-fed): участник одного сайта Clipper входит на другой под
//! своим именем, без пароля и регистрации.
//!
//! Список сайтов — CSV, по строке на сайт:
//!
//!   domain,authInsideService,authOutsideService
//!   localhost,0,0
//!   example.com,1,
//!   http://lib.example.org:8080,,1
//!
//!   authInsideService   участники сайта `domain` могут входить сюда
//!   authOutsideService  участники этого сайта могут входить на `domain`
//!
//! Значение — true|1 или false|0; пустое — «как по умолчанию». Умолчания
//! задаёт строка `localhost`: они действуют для новых сайтов и для пустых
//! значений; без неё всё, что не указано, — false. Перед именем можно
//! написать `http://` или `https://`; без этого сайт спрашивается по https
//! (сам localhost и 127.0.0.1 — по http). Строки с `#` — примечания.
//!
//!   -fed            FEDIVERSE.csv в папке библиотеки (создаётся); новые сайты
//!                    дописываются в него сами
//!   -fed ФАЙЛ.csv   то же с другим файлом
//!   -fed -          FEDIVERSE.csv, но новых сайтов не бывает: только названные
//!   -fed a.ru,b.ru  список прямо в командной строке: только эти сайты, вход
//!                    разрешён в обе стороны, файла нет
//!
//! Как проходит вход (страницы — pages/fed.zig):
//!
//!   1. участник сайта A жмёт «перейти на B»: A заводит одноразовый билет
//!      (живёт 2 минуты, выписан на B) и отправляет браузер на
//!      B/fed/in?from=A&ticket=…;
//!   2. B сам спрашивает A: GET A/fed/verify?ticket=…&for=B. A гасит билет и
//!      отвечает номером и именем участника;
//!   3. B заводит гостя «номер@A» и сеанс. Пароля у гостя нет, сеанс гаснет
//!      через 45 минут бездействия или с закрытием браузера.

const std = @import("std");
const t9n = @import("t9n.zig");

pub const Mode = enum { off, open, closed, list };
pub const Scheme = enum { auto, http, https };
pub const Entry = struct { domain: []const u8, scheme: Scheme = .auto, in: ?bool = null, out: ?bool = null };

pub const default_file = "FEDIVERSE.csv";
pub const max_entries = 10_000;
pub const max_domain = 120;
pub const ticket_ttl_s = 120;

const header = "domain,authInsideService,authOutsideService\n";

/// Что не так со списком (UTF-8) — для строки при старте.
var problem_buf: [240]u8 = undefined;
var problem_len: usize = 0;

pub fn problem() []const u8 {
    return problem_buf[0..problem_len];
}

fn complain(comptime fmt: []const u8, args: anytype) void {
    problem_len = (std.fmt.bufPrint(&problem_buf, t9n.tr(fmt), args) catch t9n.tr("-fed: список не разобран")).len;
}

pub const Name = struct { scheme: Scheme, domain: []const u8 };

/// Имя сайта в едином виде: строчными, без схемы и завершающей «/». null — не имя.
pub fn normalize(buf: *[max_domain]u8, raw: []const u8) ?Name {
    var s = std.mem.trim(u8, raw, " \t\r");
    var scheme: Scheme = .auto;
    if (std.ascii.startsWithIgnoreCase(s, "https://")) {
        scheme = .https;
        s = s[8..];
    } else if (std.ascii.startsWithIgnoreCase(s, "http://")) {
        scheme = .http;
        s = s[7..];
    }
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0 or s.len > max_domain) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
        switch (buf[i]) {
            'a'...'z', '0'...'9', '.', '-', ':', '[', ']' => {},
            else => return null,
        }
    }
    const d = buf[0..s.len];
    if (d[0] == '.' or d[0] == '-' or d[0] == ':' or std.mem.indexOf(u8, d, "..") != null) return null;
    return .{ .scheme = scheme, .domain = d };
}

/// Сама эта машина: такой сайт спрашивается по http, если схема не названа.
pub fn isLocal(domain: []const u8) bool {
    const host = if (domain.len > 0 and domain[0] == '[')
        domain[0 .. (std.mem.indexOfScalar(u8, domain, ']') orelse domain.len - 1) + 1]
    else
        domain[0 .. std.mem.indexOfScalar(u8, domain, ':') orelse domain.len];
    return std.mem.eql(u8, host, "localhost") or std.mem.endsWith(u8, host, ".localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]");
}

pub fn useHttps(scheme: Scheme, domain: []const u8) bool {
    return switch (scheme) {
        .https => true,
        .http => false,
        .auto => !isLocal(domain),
    };
}

fn parseBool(s_raw: []const u8) error{Bad}!?bool {
    const s = std.mem.trim(u8, s_raw, " \t\r");
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false")) return false;
    return error.Bad;
}

pub const Fed = struct {
    gpa: std.mem.Allocator = std.heap.page_allocator,
    mode: Mode = .off,
    /// файл списка; пусто — списка на диске нет
    path: []const u8 = "",
    /// файл лежит в папке библиотеки (иначе путь — от текущей папки)
    in_root: bool = false,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// строка `localhost`
    def_in: ?bool = null,
    def_out: ?bool = null,
    /// время и размер файла, каким мы его знаем: изменился — перечитать
    stamp: [2]i128 = .{ 0, 0 },

    pub fn on(f: *const Fed) bool {
        return f.mode != .off;
    }

    /// Можно ли править список (в панели, новыми сайтами): он лежит в файле.
    pub fn writable(f: *const Fed) bool {
        return f.path.len > 0;
    }

    pub fn allowIn(f: *const Fed, e: ?Entry) bool {
        return (if (e) |x| x.in else null) orelse f.def_in orelse false;
    }

    pub fn allowOut(f: *const Fed, e: ?Entry) bool {
        return (if (e) |x| x.out else null) orelse f.def_out orelse false;
    }

    pub fn find(f: *const Fed, domain: []const u8) ?*Entry {
        for (f.entries.items) |*e| if (std.mem.eql(u8, e.domain, domain)) return e;
        return null;
    }

    /// Открывает федерацию по значению флага `-fed` (null — выключена).
    /// Ошибка — строка в `problem()`.
    pub fn open(gpa: std.mem.Allocator, root: std.fs.Dir, spec_opt: ?[]const u8) error{BadFed}!Fed {
        const spec = spec_opt orelse return .{};
        var f = Fed{ .gpa = gpa };
        errdefer f.deinit();
        if (spec.len == 0 or std.mem.eql(u8, spec, "-")) {
            f.mode = if (spec.len == 0) .open else .closed;
            f.path = default_file;
            f.in_root = true;
        } else if (std.ascii.endsWithIgnoreCase(spec, ".csv") or isFile(spec)) {
            f.mode = .open;
            f.path = spec;
        } else {
            // список прямо во флаге: только эти сайты, в обе стороны
            f.mode = .list;
            var it = std.mem.splitScalar(u8, spec, ',');
            while (it.next()) |raw| {
                if (std.mem.trim(u8, raw, " ").len == 0) continue;
                var buf: [max_domain]u8 = undefined;
                const name = normalize(&buf, raw) orelse {
                    complain(t9n.tr("-fed: «{s}» — не имя сайта и не файл .csv"), .{raw});
                    return error.BadFed;
                };
                f.put(.{ .domain = name.domain, .scheme = name.scheme, .in = true, .out = true }) catch return oom();
            }
            if (f.entries.items.len == 0) {
                complain(t9n.tr("-fed: список сайтов пуст"), .{});
                return error.BadFed;
            }
            return f;
        }
        try f.read(root);
        return f;
    }

    fn oom() error{BadFed} {
        complain(t9n.tr("-fed: не хватает памяти"), .{});
        return error.BadFed;
    }

    fn isFile(path: []const u8) bool {
        const st = std.fs.cwd().statFile(path) catch return false;
        return st.kind == .file;
    }

    pub fn deinit(f: *Fed) void {
        f.clear();
        f.entries.deinit(f.gpa);
        f.* = .{};
    }

    fn clear(f: *Fed) void {
        for (f.entries.items) |e| f.gpa.free(e.domain);
        f.entries.clearRetainingCapacity();
        f.def_in = null;
        f.def_out = null;
    }

    /// Добавляет сайт или заменяет запись о нём.
    fn put(f: *Fed, e: Entry) !void {
        if (f.find(e.domain)) |old| {
            old.scheme = e.scheme;
            old.in = e.in;
            old.out = e.out;
            return;
        }
        if (f.entries.items.len >= max_entries) return error.OutOfMemory;
        const own = try f.gpa.dupe(u8, e.domain);
        errdefer f.gpa.free(own);
        try f.entries.append(f.gpa, .{ .domain = own, .scheme = e.scheme, .in = e.in, .out = e.out });
    }

    fn dir(f: *const Fed, root: std.fs.Dir) std.fs.Dir {
        return if (f.in_root) root else std.fs.cwd();
    }

    /// Читает файл списка; нет файла — создаёт с одной строкой умолчаний.
    fn read(f: *Fed, root: std.fs.Dir) error{BadFed}!void {
        const d = f.dir(root);
        const text = d.readFileAlloc(f.gpa, f.path, 4 << 20) catch |err| switch (err) {
            error.FileNotFound => {
                d.writeFile(.{ .sub_path = f.path, .data = header ++ "localhost,0,0\n" }) catch {
                    complain(t9n.tr("-fed: файл {s} не создаётся"), .{f.path});
                    return error.BadFed;
                };
                f.def_in = false;
                f.def_out = false;
                f.remember(root);
                return;
            },
            else => {
                complain(t9n.tr("-fed: файл {s} не читается ({s})"), .{ f.path, @errorName(err) });
                return error.BadFed;
            },
        };
        defer f.gpa.free(text);
        f.clear();
        try f.parse(text);
        f.remember(root);
    }

    fn parse(f: *Fed, text: []const u8) error{BadFed}!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var no: usize = 0;
        while (lines.next()) |raw| {
            no += 1;
            var line = std.mem.trim(u8, raw, " \t\r");
            if (no == 1 and std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];
            if (line.len == 0 or line[0] == '#') continue;
            var it = std.mem.splitScalar(u8, line, ',');
            const name_raw = it.next() orelse continue;
            const in_raw = it.next() orelse "";
            const out_raw = it.next() orelse "";
            if (it.next() != null) {
                complain(t9n.tr("{s}, строка {d}: полей больше трёх (domain,authInsideService,authOutsideService)"), .{ f.path, no });
                return error.BadFed;
            }
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, name_raw, " \t"), "domain")) continue; // заголовок
            const in = parseBool(in_raw) catch null;
            const out = parseBool(out_raw) catch null;
            if (std.meta.isError(parseBool(in_raw)) or std.meta.isError(parseBool(out_raw))) {
                complain(t9n.tr("{s}, строка {d}: значение должно быть true, false, 1, 0 или пустым"), .{ f.path, no });
                return error.BadFed;
            }
            var buf: [max_domain]u8 = undefined;
            const name = normalize(&buf, name_raw) orelse {
                complain(t9n.tr("{s}, строка {d}: «{s}» — не имя сайта"), .{ f.path, no, name_raw[0..@min(name_raw.len, 60)] });
                return error.BadFed;
            };
            if (std.mem.eql(u8, name.domain, "localhost")) {
                f.def_in = in;
                f.def_out = out;
                continue;
            }
            f.put(.{ .domain = name.domain, .scheme = name.scheme, .in = in, .out = out }) catch {
                complain(t9n.tr("{s}: сайтов больше {d} или не хватает памяти"), .{ f.path, max_entries });
                return error.BadFed;
            };
        }
    }

    fn remember(f: *Fed, root: std.fs.Dir) void {
        const st = f.dir(root).statFile(f.path) catch return;
        f.stamp = .{ st.mtime, st.size };
    }

    /// Файл списка изменили (руками или соседний воркер) — перечитать.
    /// Испорченный файл не принимается: остаётся прежний список.
    pub fn reloadIfChanged(f: *Fed, root: std.fs.Dir) void {
        if (!f.on() or !f.writable()) return;
        const st = f.dir(root).statFile(f.path) catch return;
        if (st.mtime == f.stamp[0] and st.size == f.stamp[1]) return;
        f.stamp = .{ st.mtime, st.size };
        const text = f.dir(root).readFileAlloc(f.gpa, f.path, 4 << 20) catch return;
        defer f.gpa.free(text);
        var fresh = Fed{ .gpa = f.gpa, .path = f.path };
        fresh.parse(text) catch {
            fresh.clear();
            fresh.entries.deinit(f.gpa);
            std.debug.print(t9n.tr("[clipper] {s} — список федерации оставлен прежним\n"), .{problem()});
            return;
        };
        f.clear();
        f.entries.deinit(f.gpa);
        f.entries = fresh.entries;
        f.def_in = fresh.def_in;
        f.def_out = fresh.def_out;
    }

    fn writeLine(w: anytype, e: Entry) !void {
        const b = struct {
            fn s(v: ?bool) []const u8 {
                return if (v) |x| (if (x) "1" else "0") else "";
            }
        };
        try w.print("{s}{s},{s},{s}\n", .{ switch (e.scheme) {
            .auto => "",
            .http => "http://",
            .https => "https://",
        }, e.domain, b.s(e.in), b.s(e.out) });
    }

    /// Новый сайт (режим `open`): в память и строкой в конец файла.
    pub fn add(f: *Fed, root: std.fs.Dir, name: Name) !*Entry {
        if (f.mode != .open) return error.Closed;
        try f.put(.{ .domain = name.domain, .scheme = name.scheme });
        const e = f.find(name.domain).?;
        var buf: [max_domain + 16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeLine(fbs.writer(), e.*) catch unreachable;
        const file = try f.dir(root).openFile(f.path, .{ .mode = .read_write });
        defer file.close();
        const end = try file.getEndPos();
        // файл мог кончиться без перевода строки
        var last: [1]u8 = .{'\n'};
        if (end > 0) _ = try file.preadAll(&last, end - 1);
        try file.seekTo(end);
        if (last[0] != '\n') try file.writeAll("\n");
        try file.writeAll(fbs.getWritten());
        f.remember(root);
        return e;
    }

    /// Переписывает файл целиком (правка в панели). Примечания из файла уходят.
    pub fn save(f: *Fed, root: std.fs.Dir) !void {
        if (!f.writable()) return error.Closed;
        var out = std.ArrayList(u8).init(f.gpa);
        defer out.deinit();
        try out.appendSlice(header);
        try writeLine(out.writer(), .{ .domain = "localhost", .in = f.def_in, .out = f.def_out });
        for (f.entries.items) |e| try writeLine(out.writer(), e);
        try f.dir(root).writeFile(.{ .sub_path = f.path, .data = out.items });
        f.remember(root);
    }
};

test "имя сайта" {
    var buf: [max_domain]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", normalize(&buf, " Example.COM/ ").?.domain);
    try std.testing.expectEqual(Scheme.http, normalize(&buf, "http://lib.example.org:8080").?.scheme);
    try std.testing.expectEqualStrings("lib.example.org:8080", normalize(&buf, "http://lib.example.org:8080").?.domain);
    try std.testing.expect(normalize(&buf, "") == null);
    try std.testing.expect(normalize(&buf, "a b") == null);
    try std.testing.expect(normalize(&buf, "example.com/path") == null);
    try std.testing.expect(normalize(&buf, "ex..com") == null);
    try std.testing.expect(normalize(&buf, "user@example.com") == null);
    try std.testing.expect(isLocal("localhost:3000") and isLocal("127.0.0.1") and isLocal("[::1]:80") and isLocal("a.localhost"));
    try std.testing.expect(!isLocal("example.com") and !isLocal("localhost.example.com"));
    try std.testing.expect(useHttps(.auto, "example.com") and !useHttps(.auto, "localhost:3000") and useHttps(.https, "localhost"));
}

test "список: умолчания, пустые значения, новые сайты, правка" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    // файла нет — создаётся, умолчания false
    var f = try Fed.open(gpa, tmp.dir, "");
    try std.testing.expectEqual(Mode.open, f.mode);
    try std.testing.expect(!f.allowIn(null) and !f.allowOut(null));
    var buf: [max_domain]u8 = undefined;
    const e = try f.add(tmp.dir, normalize(&buf, "New.example").?);
    try std.testing.expect(e.in == null and !f.allowIn(e.*));
    f.deinit();

    try tmp.dir.writeFile(.{ .sub_path = default_file, .data = "# наши соседи\r\ndomain,authInsideService,authOutsideService\r\nlocalhost,true,\r\na.example,,\r\nb.example,0,1\r\nhttp://c.example:8080,FALSE,TRUE" });
    f = try Fed.open(gpa, tmp.dir, "-");
    defer f.deinit();
    try std.testing.expectEqual(Mode.closed, f.mode);
    try std.testing.expectEqual(@as(usize, 3), f.entries.items.len);
    try std.testing.expect(f.allowIn(f.find("a.example").?.*) and !f.allowOut(f.find("a.example").?.*));
    try std.testing.expect(!f.allowIn(f.find("b.example").?.*) and f.allowOut(f.find("b.example").?.*));
    try std.testing.expectEqual(Scheme.http, f.find("c.example:8080").?.scheme);
    try std.testing.expect(f.allowIn(null) and !f.allowOut(null));
    try std.testing.expectError(error.Closed, f.add(tmp.dir, normalize(&buf, "x.example").?));

    // режим open: новая строка дописывается, хотя файл кончался без перевода строки
    f.mode = .open;
    _ = try f.add(tmp.dir, normalize(&buf, "d.example").?);
    const text = try tmp.dir.readFileAlloc(gpa, default_file, 1 << 16);
    defer gpa.free(text);
    try std.testing.expect(std.mem.endsWith(u8, text, "http://c.example:8080,FALSE,TRUE\nd.example,,\n"));
    try std.testing.expect(std.mem.startsWith(u8, text, "# наши соседи"));

    // правка из панели
    f.find("a.example").?.out = true;
    f.def_out = true;
    try f.save(tmp.dir);
    var g = try Fed.open(gpa, tmp.dir, "");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 4), g.entries.items.len);
    try std.testing.expect(g.allowOut(g.find("a.example").?.*) and g.allowOut(g.find("d.example").?.*) and g.find("a.example").?.in == null);

    // файл поменяли руками
    try tmp.dir.writeFile(.{ .sub_path = default_file, .data = "localhost,,\nz.example,1,1\n# дольше прежнего, чтобы размер отличался наверняка ........................................\n" });
    g.reloadIfChanged(tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), g.entries.items.len);
    try std.testing.expect(g.allowIn(g.find("z.example").?.*) and !g.allowIn(null));
}

test "список во флаге и ошибки" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    var f = try Fed.open(gpa, tmp.dir, "a.example, http://localhost:3001");
    defer f.deinit();
    try std.testing.expectEqual(Mode.list, f.mode);
    try std.testing.expect(!f.writable());
    try std.testing.expect(f.allowIn(f.find("localhost:3001").?.*) and f.allowOut(f.find("a.example").?.*));
    try std.testing.expect(!f.allowIn(null));
    try std.testing.expectError(error.BadFed, Fed.open(gpa, tmp.dir, "не сайт"));
    try tmp.dir.writeFile(.{ .sub_path = default_file, .data = "a.example,да,\n" });
    try std.testing.expectError(error.BadFed, Fed.open(gpa, tmp.dir, ""));
    try std.testing.expect(std.mem.indexOf(u8, problem(), if (@import("config").lang == .en) "line 1" else "строка 1") != null);
    try tmp.dir.writeFile(.{ .sub_path = default_file, .data = "a.example,1,1,1\n" });
    try std.testing.expectError(error.BadFed, Fed.open(gpa, tmp.dir, ""));
    var off = try Fed.open(gpa, tmp.dir, null);
    try std.testing.expect(!off.on());
    off.deinit();
}
