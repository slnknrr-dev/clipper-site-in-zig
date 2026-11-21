//! Каталоги перевода интерфейса.
//!
//!   t9n extract SRC DIR      обойти исходники, записать DIR/ru.t9n (эталон ключей)
//!                            и дописать новые ключи в каталоги остальных языков (DIR/en.t9n)
//!   t9n compile ui.t9n OUT   каталог → модуль `t9n_table` (делает build.zig при -Dlang)
//!
//! Каталог — текст в UTF-8:
//!
//!   # src/pages/main.zig      примечание: откуда ключи ниже
//!   < Русская строка          ключ, как в исходнике
//!   > Перевод                 пусто — не переведено, останется русским
//!
//! В строках `\n` — перевод строки, `\\` — обратная черта. Ключ — строка
//! исходника целиком, с разметкой и местами подстановки (`{d}`, `{h}`, `{U}…{E}`):
//! в переводе они должны стоять в том же порядке.
//!
//! Ключи: строковые литералы `.zig` с нелатинскими буквами (кроме тестов и
//! многострочных `\\`) и куски шаблонов `src/tpl/*.html` между `{{…}}`.

const std = @import("std");

const Entry = struct { key: []const u8, val: []const u8 = "", from: []const u8 = "" };

fn nonAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return true;
    return false;
}

fn escape(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i],
            });
        } else try out.append(s[i]);
    }
    return out.items;
}

/// Разбор каталога. Ошибка формата — сообщение и выход.
fn parseCatalog(a: std.mem.Allocator, path: []const u8, text_in: []const u8) ![]Entry {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    var list = std.ArrayList(Entry).init(a);
    var key: ?[]const u8 = null;
    var from: []const u8 = "";
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            from = std.mem.trim(u8, line[1..], " ");
        } else if (line[0] == '<') {
            if (key != null) die("{s}:{d}: у предыдущего ключа нет строки «>»", .{ path, n });
            key = try unescape(a, if (line.len > 1 and line[1] == ' ') line[2..] else line[1..]);
        } else if (line[0] == '>') {
            const k = key orelse die("{s}:{d}: «>» без ключа «<»", .{ path, n });
            try list.append(.{ .key = k, .val = try unescape(a, if (line.len > 1 and line[1] == ' ') line[2..] else line[1..]), .from = from });
            key = null;
        } else die("{s}:{d}: строка должна начинаться с «#», «<» или «>»", .{ path, n });
    }
    if (key != null) die("{s}: у последнего ключа нет строки «>»", .{path});
    return list.items;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("t9n: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Места подстановки `W.f` в строке, по порядку: перевод обязан их сохранить.
fn specs(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == '{' and s[i + 2] == '}' and std.mem.indexOfScalar(u8, "shbqdUE", s[i + 1]) != null) try out.append(s[i + 1]);
    }
    return out.items;
}

fn compile(a: std.mem.Allocator, catalog: []const u8, out_path: []const u8) !void {
    const entries = try parseCatalog(a, catalog, try std.fs.cwd().readFileAlloc(a, catalog, 64 << 20));
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("//! Таблица перевода. Файл сделан tools/t9n.zig из каталога src/t9n/ЯЗЫК.t9n — руками не править.\n");
    try w.writeAll("pub const pairs = [_]struct { []const u8, []const u8 }{\n");
    var seen = std.StringHashMap(void).init(a);
    for (entries) |e| {
        if (e.val.len == 0 or std.mem.eql(u8, e.key, e.val)) continue;
        if (seen.contains(e.key)) die("{s}: ключ повторяется: {s}", .{ catalog, e.key });
        try seen.put(e.key, {});
        if (!std.mem.eql(u8, try specs(a, e.key), try specs(a, e.val))) die("{s}: в переводе другие места подстановки, чем в ключе: {s}", .{ catalog, e.key });
        // Куски склеиваются в страницу как есть: потерянный пробел по краю слепляет слова.
        if (edge(e.key, true) != edge(e.val, true) or edge(e.key, false) != edge(e.val, false)) die("{s}: у перевода другие пробелы по краям, чем у ключа: «{s}»", .{ catalog, e.key });
        try w.print("    .{{ \"{}\", \"{}\" }},\n", .{ std.zig.fmtEscapes(e.key), std.zig.fmtEscapes(e.val) });
    }
    try w.writeAll("};\n");
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out.items });
}

const Collector = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Entry),
    seen: std.StringHashMap(void),

    fn add(c: *Collector, key: []const u8, from: []const u8) !void {
        if (!nonAscii(key) or c.seen.contains(key)) return;
        // "\x97" и подобное — уже байты windows-1251, а не текст для перевода.
        if (!std.unicode.utf8ValidateSlice(key)) return;
        try c.seen.put(key, {});
        try c.list.append(.{ .key = key, .from = from });
    }

    fn zig(c: *Collector, from: []const u8, src: [:0]const u8) !void {
        var tok = std.zig.Tokenizer.init(src);
        // Тесты пропускаются: `test "…" { … }` до парной скобки.
        var skip_depth: ?usize = null;
        var depth: usize = 0;
        var after_test = false;
        while (true) {
            const t = tok.next();
            switch (t.tag) {
                .eof => break,
                .keyword_test => after_test = true,
                .l_brace => {
                    if (after_test and skip_depth == null) skip_depth = depth;
                    after_test = false;
                    depth += 1;
                },
                .r_brace => {
                    depth -|= 1;
                    if (skip_depth) |d| if (depth == d) {
                        skip_depth = null;
                    };
                },
                .string_literal => {
                    if (after_test or skip_depth != null) continue;
                    const raw = src[t.loc.start..t.loc.end];
                    const s = std.zig.string_literal.parseAlloc(c.a, raw) catch continue;
                    try c.add(s, from);
                },
                else => {},
            }
        }
    }

    fn html(c: *Collector, from: []const u8, src: []const u8) !void {
        var rest = src;
        while (std.mem.indexOf(u8, rest, "{{")) |open| {
            const close = std.mem.indexOfPos(u8, rest, open, "}}") orelse break;
            try c.add(rest[0..open], from);
            rest = rest[close + 2 ..];
        }
        try c.add(rest, from);
    }
};

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn writeCatalog(a: std.mem.Allocator, path: []const u8, head: []const u8, entries: []const Entry) !void {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll(head);
    var from: []const u8 = "";
    for (entries) |e| {
        if (!std.mem.eql(u8, from, e.from)) {
            from = e.from;
            try w.print("\n# {s}\n", .{from});
        }
        try w.writeAll("< ");
        try escape(w, e.key);
        try w.writeAll("\n>");
        if (e.val.len > 0) {
            try w.writeByte(' ');
            try escape(w, e.val);
        }
        try w.writeByte('\n');
    }
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn extract(a: std.mem.Allocator, src_dir: []const u8, t9n_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(src_dir, .{ .iterate = true });
    defer dir.close();
    var paths = std.ArrayList([]const u8).init(a);
    var walker = try dir.walk(a);
    while (try walker.next()) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.path, ".zig") or std.mem.endsWith(u8, e.path, ".html")) {
            const p = try a.dupe(u8, e.path);
            std.mem.replaceScalar(u8, p, '\\', '/');
            try paths.append(p);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);

    var c = Collector{ .a = a, .list = std.ArrayList(Entry).init(a), .seen = std.StringHashMap(void).init(a) };
    for (paths.items) |p| {
        const from = try std.fmt.allocPrint(a, "src/{s}", .{p});
        const bytes = try dir.readFileAllocOptions(a, p, 64 << 20, null, 1, 0);
        if (std.mem.endsWith(u8, p, ".zig")) try c.zig(from, bytes) else try c.html(from, bytes);
    }

    const ru = try std.fmt.allocPrint(a, "{s}/ru.t9n", .{t9n_dir});
    try writeCatalog(a, ru,
        \\# Эталон ключей перевода интерфейса. Файл пишет `zig build t9n` — руками не править.
        \\# Перевод — в src/t9n/ЯЗЫК.t9n: тот же файл, после «>» — перевод.
        \\# Формат и правила — в начале tools/t9n.zig.
        \\
    , c.list.items);
    std.debug.print("t9n: {s}: ключей {d}\n", .{ ru, c.list.items.len });

    // Остальные языки: переводы сохраняются, новые ключи дописываются пустыми,
    // исчезнувшие из исходников уходят в конец под «# устарело».
    var langs = std.fs.cwd().openDir(t9n_dir, .{ .iterate = true }) catch return;
    defer langs.close();
    var it = langs.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".t9n") or std.mem.eql(u8, e.name, "ru.t9n")) continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ t9n_dir, e.name });
        const old_text = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch continue;
        const old = try parseCatalog(a, path, old_text);
        var have = std.StringHashMap([]const u8).init(a);
        for (old) |o| try have.put(o.key, o.val);
        var merged = std.ArrayList(Entry).init(a);
        var done: usize = 0;
        for (c.list.items) |k| {
            const v = have.get(k.key) orelse "";
            if (v.len > 0) done += 1;
            try merged.append(.{ .key = k.key, .val = v, .from = k.from });
        }
        for (old) |o| {
            if (!c.seen.contains(o.key) and o.val.len > 0) try merged.append(.{ .key = o.key, .val = o.val, .from = "устарело: такой строки в исходниках больше нет" });
        }
        try writeCatalog(a, path, "# Перевод интерфейса. Ключи обновляет `zig build t9n`; переводы после «>» сохраняются.\n", merged.items);
        std.debug.print("t9n: {s}: переведено {d} из {d}\n", .{ path, done, c.list.items.len });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len == 4 and std.mem.eql(u8, argv[1], "extract")) return extract(a, argv[2], argv[3]);
    if (argv.len == 4 and std.mem.eql(u8, argv[1], "compile")) return compile(a, argv[2], argv[3]);
    die("t9n extract SRC DIR | t9n compile ЯЗЫК.t9n OUT.zig", .{});
}

/// Сколько пробелов в начале (`start`) или в конце строки.
fn edge(s: []const u8, start: bool) usize {
    var n: usize = 0;
    if (start) {
        while (n < s.len and s[n] == ' ') n += 1;
    } else {
        while (n < s.len and s[s.len - 1 - n] == ' ') n += 1;
    }
    return n;
}
