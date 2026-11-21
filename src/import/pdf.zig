//! PDF → книга: только текстовый слой, без распознавания картинок.
//!
//! Как читается файл:
//!   объекты    таблица ссылок (xref) не используется: файл просматривается
//!              целиком, каждый «N G obj» запоминается (поздний заменяет
//!              ранний, как при дозаписи), потоки объектов (ObjStm) раскрываются;
//!   страницы   дерево от каталога; содержимое — операторы текста (Tj, TJ, ', ")
//!              с матрицами, шрифтом и ширинами знаков;
//!   шрифты     таблица ToUnicode; без неё — имена знаков из /Differences, а
//!              для остального байт считается знаком windows-1251;
//!   абзацы     строки собираются по координатам: новый абзац — это больший
//!              шаг между строками, красная строка или короткая строка с точкой;
//!   главы      верхний уровень оглавления (Outlines), если оно есть.
//!
//! Скан без текстового слоя, файл с паролем и текст, который не переводится в
//! буквы (шрифт без таблицы), отвергаются с понятной причиной.
//!
//! Вход враждебен: глубина вложенности и объём работы ограничены, границы
//! срезов проверяются, числа с плавающей точкой в целые не приводятся без проверки.

const std = @import("std");
const cp = @import("../cp1251.zig");
const common = @import("common.zig");
const fb2 = @import("../fb2.zig");

const Parsed = fb2.Parsed;
const Chapter = fb2.Chapter;
const Budget = common.Budget;

pub const Error = common.Error || error{ NotPdf, Encrypted, NoText, Garbled };

const max_depth = 40;
const max_pages = 50000;
const max_form_depth = 6;

// ───────────── значения ─────────────

const Value = union(enum) {
    null,
    boolean: bool,
    num: f64,
    name: []const u8,
    str: []const u8,
    array: []const Value,
    dict: []const Pair,
    ref: u32,
    /// Слово-оператор (в потоке содержимого и в CMap).
    op: []const u8,
};
const Pair = struct { key: []const u8, val: Value };

fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0x0C or c == 0;
}
fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}
fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

const Lex = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    budget: *Budget,

    fn ws(l: *Lex) void {
        while (l.i < l.s.len) {
            if (isWs(l.s[l.i])) {
                l.i += 1;
            } else if (l.s[l.i] == '%') {
                while (l.i < l.s.len and l.s[l.i] != '\n' and l.s[l.i] != '\r') l.i += 1;
            } else break;
        }
    }

    fn word(l: *Lex) []const u8 {
        const from = l.i;
        while (l.i < l.s.len and !isWs(l.s[l.i]) and !isDelim(l.s[l.i])) l.i += 1;
        return l.s[from..l.i];
    }

    /// Следующее значение; null — конец входа или лишняя закрывающая скобка.
    fn value(l: *Lex, depth: usize) Error!?Value {
        l.ws();
        if (l.i >= l.s.len) return null;
        try l.budget.take(24);
        const c = l.s[l.i];
        switch (c) {
            '/' => {
                l.i += 1;
                const raw = l.word();
                if (std.mem.indexOfScalar(u8, raw, '#') == null) return .{ .name = raw };
                const out = try l.a.alloc(u8, raw.len);
                var n: usize = 0;
                var k: usize = 0;
                while (k < raw.len) : (k += 1) {
                    if (raw[k] == '#' and k + 2 < raw.len) {
                        if (hexVal(raw[k + 1])) |hi| if (hexVal(raw[k + 2])) |lo| {
                            out[n] = hi * 16 + lo;
                            n += 1;
                            k += 2;
                            continue;
                        };
                    }
                    out[n] = raw[k];
                    n += 1;
                }
                return .{ .name = out[0..n] };
            },
            '(' => return .{ .str = try l.literal() },
            '<' => {
                if (l.i + 1 < l.s.len and l.s[l.i + 1] == '<') {
                    l.i += 2;
                    if (depth >= max_depth) return error.Damaged;
                    var list = std.ArrayList(Pair).init(l.a);
                    while (true) {
                        l.ws();
                        if (l.i >= l.s.len) break;
                        if (l.s[l.i] == '>') {
                            l.i = @min(l.s.len, l.i + 2);
                            break;
                        }
                        const before = l.i;
                        const k = (try l.value(depth + 1)) orelse {
                            if (l.i == before) l.i += 1; // лишняя скобка: пропустить
                            continue;
                        };
                        if (k != .name) continue;
                        const v = (try l.value(depth + 1)) orelse break;
                        try list.append(.{ .key = k.name, .val = v });
                    }
                    return .{ .dict = list.items };
                }
                l.i += 1;
                var out = std.ArrayList(u8).init(l.a);
                var half: ?u8 = null;
                while (l.i < l.s.len and l.s[l.i] != '>') : (l.i += 1) {
                    const h = hexVal(l.s[l.i]) orelse continue;
                    if (half) |hi| {
                        try out.append(hi * 16 + h);
                        half = null;
                    } else half = h;
                }
                if (half) |hi| try out.append(hi * 16);
                if (l.i < l.s.len) l.i += 1;
                try l.budget.take(out.items.len);
                return .{ .str = out.items };
            },
            '[' => {
                l.i += 1;
                if (depth >= max_depth) return error.Damaged;
                var list = std.ArrayList(Value).init(l.a);
                while (true) {
                    l.ws();
                    if (l.i >= l.s.len) break;
                    if (l.s[l.i] == ']') {
                        l.i += 1;
                        break;
                    }
                    const before = l.i;
                    const v = (try l.value(depth + 1)) orelse {
                        if (l.i == before) l.i += 1;
                        continue;
                    };
                    try list.append(v);
                }
                return .{ .array = list.items };
            },
            ')', '>', ']', '{', '}' => return null,
            else => {},
        }
        const w = l.word();
        if (w.len == 0) {
            l.i += 1;
            return null;
        }
        if ((c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.') {
            const x = std.fmt.parseFloat(f64, w) catch return .{ .op = w };
            if (!std.math.isFinite(x)) return .{ .num = 0 };
            // «N G R» — ссылка на объект
            if (c >= '0' and c <= '9' and std.mem.indexOfScalar(u8, w, '.') == null and x >= 0 and x < 4294967295) {
                const save = l.i;
                l.ws();
                const g = l.word();
                if (g.len > 0 and g.len <= 5 and std.mem.indexOfNone(u8, g, "0123456789") == null) {
                    l.ws();
                    if (l.i < l.s.len and l.s[l.i] == 'R' and (l.i + 1 == l.s.len or isWs(l.s[l.i + 1]) or isDelim(l.s[l.i + 1]))) {
                        l.i += 1;
                        return .{ .ref = @intFromFloat(x) };
                    }
                }
                l.i = save;
            }
            return .{ .num = x };
        }
        if (std.mem.eql(u8, w, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, w, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, w, "null")) return .null;
        return .{ .op = w };
    }

    fn literal(l: *Lex) Error![]const u8 {
        l.i += 1; // «(»
        var out = std.ArrayList(u8).init(l.a);
        var nest: usize = 0;
        while (l.i < l.s.len) : (l.i += 1) {
            const c = l.s[l.i];
            if (c == '\\') {
                l.i += 1;
                if (l.i >= l.s.len) break;
                const e = l.s[l.i];
                switch (e) {
                    'n' => try out.append('\n'),
                    'r' => try out.append('\r'),
                    't' => try out.append('\t'),
                    'b' => try out.append(8),
                    'f' => try out.append(12),
                    '0'...'7' => {
                        var v: u32 = e - '0';
                        var k: usize = 0;
                        while (k < 2 and l.i + 1 < l.s.len and l.s[l.i + 1] >= '0' and l.s[l.i + 1] <= '7') : (k += 1) {
                            l.i += 1;
                            v = v * 8 + (l.s[l.i] - '0');
                        }
                        try out.append(@truncate(v));
                    },
                    '\r' => if (l.i + 1 < l.s.len and l.s[l.i + 1] == '\n') {
                        l.i += 1;
                    },
                    '\n' => {},
                    else => try out.append(e),
                }
            } else if (c == '(') {
                nest += 1;
                try out.append(c);
            } else if (c == ')') {
                if (nest == 0) {
                    l.i += 1;
                    break;
                }
                nest -= 1;
                try out.append(c);
            } else try out.append(c);
        }
        try l.budget.take(out.items.len);
        return out.items;
    }
};

fn get(v: Value, key: []const u8) ?Value {
    if (v != .dict) return null;
    for (v.dict) |p| if (std.mem.eql(u8, p.key, key)) return p.val;
    return null;
}

fn toInt(v: ?Value) ?i64 {
    const x = v orelse return null;
    if (x != .num or !(@abs(x.num) < 1e15)) return null;
    return @intFromFloat(@trunc(x.num));
}

fn toNum(v: Value) f64 {
    return if (v == .num) v.num else 0;
}

fn isName(v: ?Value, name: []const u8) bool {
    const x = v orelse return false;
    return x == .name and std.mem.eql(u8, x.name, name);
}

// ───────────── документ ─────────────

const Obj = struct { val: Value, stream: ?[]const u8 = null };

const Doc = struct {
    a: std.mem.Allocator,
    bytes: []const u8,
    budget: *Budget,
    objs: std.AutoHashMapUnmanaged(u32, Obj) = .{},
    fonts: std.AutoHashMapUnmanaged(u32, *Font) = .{},
    root: ?Value = null,
    info: ?Value = null,
    encrypted: bool = false,
    /// Сколько операторов и знаков уже обработано (защита от зацикленных форм).
    work: usize = 0,
    unknown: usize = 0,
    glyphs: usize = 0,

    fn spend(d: *Doc, n: usize) Error!void {
        d.work += n;
        if (d.work > 400_000_000) return error.TooBig;
    }

    fn resolve(d: *Doc, v_in: ?Value) Value {
        var v = v_in orelse return .null;
        var hops: usize = 0;
        while (v == .ref and hops < 32) : (hops += 1) {
            v = if (d.objs.get(v.ref)) |o| o.val else return .null;
        }
        return if (v == .ref) .null else v;
    }

    fn field(d: *Doc, v: Value, key: []const u8) Value {
        return d.resolve(get(v, key));
    }

    /// Просматривает файл и запоминает все объекты.
    fn scan(d: *Doc) Error!void {
        const b = d.bytes;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, b, pos, "obj")) |k| {
            pos = k + 3;
            if (k > 0 and b[k - 1] == 'd') continue; // endobj
            if (pos < b.len and !isWs(b[pos]) and !isDelim(b[pos])) continue;
            // назад: пробелы, поколение, пробелы, номер
            var j = k;
            const ws1 = j;
            while (j > 0 and isWs(b[j - 1])) j -= 1;
            if (j == ws1) continue;
            const gen_end = j;
            while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
            if (j == gen_end) continue;
            const ws2 = j;
            while (j > 0 and isWs(b[j - 1])) j -= 1;
            if (j == ws2) continue;
            const num_end = j;
            while (j > 0 and b[j - 1] >= '0' and b[j - 1] <= '9') j -= 1;
            if (j == num_end or num_end - j > 10) continue;
            if (j > 0 and !isWs(b[j - 1]) and !isDelim(b[j - 1])) continue;
            const num = std.fmt.parseInt(u32, b[j..num_end], 10) catch continue;

            var lex = Lex{ .a = d.a, .s = b, .i = pos, .budget = d.budget };
            const val = (lex.value(0) catch |err| switch (err) {
                error.Damaged => continue,
                else => |e| return e,
            }) orelse continue;
            var obj = Obj{ .val = val };
            lex.ws();
            if (val == .dict and std.mem.startsWith(u8, b[lex.i..], "stream")) {
                var from = lex.i + 6;
                if (from < b.len and b[from] == '\r') from += 1;
                if (from < b.len and b[from] == '\n') from += 1;
                from = @min(from, b.len);
                var to: ?usize = null;
                if (toInt(get(val, "Length"))) |len| if (len >= 0 and @as(u64, @intCast(len)) <= b.len - from) {
                    var e = from + @as(usize, @intCast(len));
                    const data_end = e;
                    while (e < b.len and isWs(b[e])) e += 1;
                    if (std.mem.startsWith(u8, b[e..], "endstream")) to = data_end;
                };
                if (to == null) {
                    var e = std.mem.indexOfPos(u8, b, from, "endstream") orelse b.len;
                    if (e > from and b[e - 1] == '\n') e -= 1;
                    if (e > from and b[e - 1] == '\r') e -= 1;
                    to = e;
                }
                obj.stream = b[from..to.?];
                lex.i = to.?;
            }
            pos = @max(pos, lex.i);
            try d.budget.take(64);
            try d.objs.put(d.a, num, obj);
            if (val == .dict) d.noteTrailer(val);
        }
        // словари «trailer» старого вида
        pos = 0;
        while (std.mem.indexOfPos(u8, b, pos, "trailer")) |k| {
            pos = k + 7;
            var lex = Lex{ .a = d.a, .s = b, .i = pos, .budget = d.budget };
            const val = (lex.value(0) catch continue) orelse continue;
            if (val == .dict) d.noteTrailer(val);
        }
    }

    fn noteTrailer(d: *Doc, dict: Value) void {
        if (get(dict, "Encrypt") != null) d.encrypted = true;
        if (get(dict, "Root")) |r| d.root = r;
        if (get(dict, "Info")) |r| d.info = r;
    }

    /// Раскрывает потоки объектов (PDF 1.5): сжатые объекты становятся обычными.
    fn expandObjectStreams(d: *Doc) Error!void {
        var nums = std.ArrayList(u32).init(d.a);
        var it = d.objs.iterator();
        while (it.next()) |e| if (e.value_ptr.stream != null and isName(get(e.value_ptr.val, "Type"), "ObjStm")) try nums.append(e.key_ptr.*);
        for (nums.items) |num| {
            const obj = d.objs.get(num).?;
            const data = d.decode(obj) catch |err| switch (err) {
                error.Damaged => continue,
                else => |e| return e,
            };
            const n = toInt(get(obj.val, "N")) orelse continue;
            const first = toInt(get(obj.val, "First")) orelse continue;
            if (n <= 0 or n > 1_000_000 or first < 0 or @as(u64, @intCast(first)) > data.len) continue;
            var head = Lex{ .a = d.a, .s = data[0..@intCast(first)], .budget = d.budget };
            var k: i64 = 0;
            while (k < n) : (k += 1) {
                const id = toInt(head.value(0) catch break) orelse break;
                const off = toInt(head.value(0) catch break) orelse break;
                if (id < 0 or id > 0xFFFFFFFE or off < 0) continue;
                const at = @as(u64, @intCast(first)) + @as(u64, @intCast(off));
                if (at >= data.len) continue;
                if (d.objs.contains(@intCast(id))) continue;
                var lex = Lex{ .a = d.a, .s = data, .i = @intCast(at), .budget = d.budget };
                const val = (lex.value(0) catch continue) orelse continue;
                try d.budget.take(64);
                try d.objs.put(d.a, @intCast(id), .{ .val = val });
                if (val == .dict and isName(get(val, "Type"), "Catalog") and d.root == null) d.root = val;
            }
        }
    }

    // ───────────── потоки ─────────────

    fn decode(d: *Doc, obj: Obj) Error![]const u8 {
        var data = obj.stream orelse return error.Damaged;
        const filter = d.field(obj.val, "Filter");
        const parms = d.field(obj.val, "DecodeParms");
        const one = [1]Value{filter};
        const filters: []const Value = switch (filter) {
            .name => &one,
            .array => |arr| arr,
            else => return data,
        };
        for (filters, 0..) |f_raw, i| {
            const f = d.resolve(f_raw);
            if (f != .name) return error.Damaged;
            const p = switch (parms) {
                .dict => if (i == 0) parms else Value.null,
                .array => |arr| if (i < arr.len) d.resolve(arr[i]) else Value.null,
                else => Value.null,
            };
            const n = f.name;
            if (std.mem.eql(u8, n, "FlateDecode") or std.mem.eql(u8, n, "Fl")) {
                var out = try common.inflate(d.a, .zlib, data, d.budget, false);
                if (out.len == 0 and data.len > 2) out = try common.inflate(d.a, .raw, data, d.budget, false);
                data = try d.unpredict(out, p);
            } else if (std.mem.eql(u8, n, "LZWDecode") or std.mem.eql(u8, n, "LZW")) {
                data = try d.unpredict(try lzw(d.a, data, d.budget, (toInt(get(p, "EarlyChange")) orelse 1) != 0), p);
            } else if (std.mem.eql(u8, n, "ASCIIHexDecode") or std.mem.eql(u8, n, "AHx")) {
                var out = std.ArrayList(u8).init(d.a);
                var half: ?u8 = null;
                for (data) |c| {
                    if (c == '>') break;
                    const h = hexVal(c) orelse continue;
                    if (half) |hi| {
                        try out.append(hi * 16 + h);
                        half = null;
                    } else half = h;
                }
                try d.budget.take(out.items.len);
                data = out.items;
            } else if (std.mem.eql(u8, n, "ASCII85Decode") or std.mem.eql(u8, n, "A85")) {
                data = try ascii85(d.a, data, d.budget);
            } else if (std.mem.eql(u8, n, "RunLengthDecode") or std.mem.eql(u8, n, "RL")) {
                var out = std.ArrayList(u8).init(d.a);
                var at2: usize = 0;
                while (at2 < data.len) {
                    const len = data[at2];
                    at2 += 1;
                    if (len == 128) break;
                    if (len < 128) {
                        const cnt = @min(@as(usize, len) + 1, data.len - at2);
                        try d.budget.take(cnt);
                        try out.appendSlice(data[at2..][0..cnt]);
                        at2 += cnt;
                    } else if (at2 < data.len) {
                        const cnt = 257 - @as(usize, len);
                        try d.budget.take(cnt);
                        try out.appendNTimes(data[at2], cnt);
                        at2 += 1;
                    }
                }
                data = out.items;
            } else return error.Damaged; // картинки и шифрование: текста там нет
        }
        return data;
    }

    /// Снимает предсказание PNG (применяется к потокам объектов).
    fn unpredict(d: *Doc, data: []u8, parms: Value) Error![]const u8 {
        const predictor = toInt(get(parms, "Predictor")) orelse 1;
        if (predictor < 10) return if (predictor == 1) data else error.Damaged;
        const colors = toInt(get(parms, "Colors")) orelse 1;
        const columns = toInt(get(parms, "Columns")) orelse 1;
        const bpc = toInt(get(parms, "BitsPerComponent")) orelse 8;
        if (colors < 1 or colors > 16 or columns < 1 or columns > 1 << 20 or bpc != 8) return error.Damaged;
        const bpp: usize = @intCast(colors);
        const row: usize = @as(usize, @intCast(columns)) * bpp;
        const out = try d.a.alloc(u8, data.len);
        var n: usize = 0;
        var at: usize = 0;
        var prev: []const u8 = &.{};
        while (at + 1 + row <= data.len) : (at += 1 + row) {
            const kind = data[at];
            const src = data[at + 1 ..][0..row];
            const dst = out[n..][0..row];
            for (src, 0..) |x, i| {
                const left: u8 = if (i >= bpp) dst[i - bpp] else 0;
                const up: u8 = if (prev.len == row) prev[i] else 0;
                const ul: u8 = if (prev.len == row and i >= bpp) prev[i - bpp] else 0;
                dst[i] = x +% switch (kind) {
                    1 => left,
                    2 => up,
                    3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                    4 => blk: {
                        const pa = @abs(@as(i32, up) - ul);
                        const pb = @abs(@as(i32, left) - ul);
                        const pc = @abs(@as(i32, left) + up - 2 * @as(i32, ul));
                        break :blk if (pa <= pb and pa <= pc) left else if (pb <= pc) up else ul;
                    },
                    else => 0,
                };
            }
            prev = dst;
            n += row;
        }
        return out[0..n];
    }
};

fn ascii85(a: std.mem.Allocator, data: []const u8, budget: *Budget) Error![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var group: [5]u8 = undefined;
    var n: usize = 0;
    for (data) |c| {
        if (c == '~') break;
        if (isWs(c)) continue;
        if (c == 'z' and n == 0) {
            try budget.take(4);
            try out.appendSlice(&.{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') continue;
        group[n] = c - '!';
        n += 1;
        if (n == 5) {
            var v: u64 = 0;
            for (group) |g| v = v * 85 + g;
            try budget.take(4);
            try out.appendSlice(&.{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
            n = 0;
        }
    }
    if (n > 1) {
        var v: u64 = 0;
        for (0..5) |i| v = v * 85 + (if (i < n) group[i] else 84);
        const full = [4]u8{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
        try budget.take(4);
        try out.appendSlice(full[0 .. n - 1]);
    }
    return out.items;
}

fn lzw(a: std.mem.Allocator, data: []const u8, budget: *Budget, early: bool) Error![]u8 {
    var out = std.ArrayList(u8).init(a);
    // запись словаря: предыдущий код и последний байт; строка восстанавливается задом наперёд
    const prev = try a.alloc(u16, 4096);
    const last = try a.alloc(u8, 4096);
    const stack = try a.alloc(u8, 4097);
    var next: u16 = 258;
    var width: u4 = 9;
    var bits: u32 = 0;
    var have: u5 = 0;
    var old: ?u16 = null;
    var i: usize = 0;
    while (true) {
        while (have < width and i < data.len) {
            bits = (bits << 8) | data[i];
            i += 1;
            have += 8;
        }
        if (have < width) break;
        const code: u16 = @intCast((bits >> (have - width)) & ((@as(u32, 1) << width) - 1));
        have -= width;
        if (code == 257) break;
        if (code == 256) {
            next = 258;
            width = 9;
            old = null;
            continue;
        }
        if (code > next or (code == next and old == null)) break; // испорчено
        // строка кода (или «старая + её первый байт», если код ещё не в словаре)
        var sp: usize = 0;
        var cur: u16 = if (code == next) old.? else code;
        while (cur >= 258 and sp < 4096) : (sp += 1) {
            stack[sp] = last[cur];
            cur = prev[cur];
        }
        if (cur >= 256) break;
        const first: u8 = @intCast(cur);
        stack[sp] = first;
        sp += 1;
        try budget.take(sp + 1);
        var k = sp;
        while (k > 0) : (k -= 1) try out.append(stack[k - 1]);
        if (code == next) try out.append(first);
        if (old) |o| if (next < 4096) {
            prev[next] = o;
            last[next] = first;
            next += 1;
        };
        old = code;
        const edge: u16 = if (early) 1 else 0;
        if (next + edge >= 2048) width = 12 else if (next + edge >= 1024) width = 11 else if (next + edge >= 512) width = 10 else width = 9;
    }
    return out.items;
}

// ───────────── шрифты ─────────────

const Font = struct {
    /// Код знака — два байта (составной шрифт).
    two: bool = false,
    /// Код → текст в windows-1251 (из ToUnicode и /Differences).
    map: std.AutoHashMapUnmanaged(u32, []const u8) = .{},
    /// Простой шрифт без таблицы: байт и есть знак (латиница, а старшая
    /// половина — windows-1251: так устроены старые русские PDF).
    plain: bool = true,
    first: u32 = 0,
    widths: []const f32 = &.{},
    cid_widths: std.AutoHashMapUnmanaged(u32, f32) = .{},
    default_width: f32 = 500,

    fn text(f: *const Font, code: u32) ?[]const u8 {
        if (f.map.get(code)) |t| return t;
        if (!f.plain or code > 255) return null;
        if (code < 0x20) return "";
        return common.oneByte(@intCast(code));
    }

    fn width(f: *const Font, code: u32) f32 {
        if (f.two) return f.cid_widths.get(code) orelse f.default_width;
        if (code >= f.first and code - f.first < f.widths.len) return f.widths[code - f.first];
        return f.default_width;
    }
};

fn utf16ToCp(a: std.mem.Allocator, be: []const u8, bump: u32) Error![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i + 1 < be.len) : (i += 2) {
        var u: u32 = (@as(u32, be[i]) << 8) | be[i + 1];
        if (i + 2 >= be.len) u +%= bump; // диапазон: растёт последняя единица
        u &= 0xFFFF;
        if (u >= 0xD800 and u <= 0xDBFF and i + 3 < be.len) {
            const lo = (@as(u32, be[i + 2]) << 8) | be[i + 3];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        if (u == 0 or (u >= 0xD800 and u <= 0xDFFF) or u > 0x10FFFF) continue;
        try out.appendSlice(common.fromUnicode(@intCast(u)));
    }
    return out.items;
}

fn codeOf(s: []const u8) u32 {
    var v: u32 = 0;
    for (s[0..@min(s.len, 4)]) |c| v = (v << 8) | c;
    return v;
}

/// Имя знака PostScript → символ Юникода.
fn glyph(name_in: []const u8) ?u21 {
    var name = name_in;
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| if (dot > 0) {
        name = name[0..dot]; // «a.sc», «one.oldstyle»
    };
    if (name.len == 1) return name[0];
    if (name.len == 7 and std.mem.startsWith(u8, name, "uni")) return std.fmt.parseInt(u21, name[3..], 16) catch null;
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u') if (std.fmt.parseInt(u21, name[1..], 16)) |u| return u else |_| {};
    if (name.len == 9 and std.mem.startsWith(u8, name, "afii")) {
        const n = std.fmt.parseInt(u32, name[4..], 10) catch return null;
        return switch (n) {
            10017...10022 => @intCast(0x410 + n - 10017),
            10023 => 0x401,
            10024...10049 => @intCast(0x416 + n - 10024),
            10065...10070 => @intCast(0x430 + n - 10065),
            10071 => 0x451,
            10072...10097 => @intCast(0x436 + n - 10072),
            61352 => 0x2116,
            else => null,
        };
    }
    if (std.mem.endsWith(u8, name, "cyrillic")) {
        const stems = [_][]const u8{ "a", "be", "ve", "ge", "de", "ie", "zhe", "ze", "ii", "iishort", "ka", "el", "em", "en", "o", "pe", "er", "es", "te", "u", "ef", "kha", "tse", "che", "sha", "shcha", "hardsign", "yeri", "softsign", "ereversed", "iu", "ia" };
        const stem = name[0 .. name.len - 8];
        if (std.ascii.eqlIgnoreCase(stem, "io")) return if (stem[0] == 'I') 0x401 else 0x451;
        for (stems, 0..) |s, i| if (std.ascii.eqlIgnoreCase(stem, s)) {
            return @intCast((if (stem[0] >= 'A' and stem[0] <= 'Z') @as(u32, 0x410) else 0x430) + i);
        };
        return null;
    }
    const table = .{
        .{ "space", ' ' },         .{ "exclam", '!' },        .{ "quotedbl", '"' },      .{ "numbersign", '#' },     .{ "dollar", '$' },        .{ "percent", '%' },
        .{ "ampersand", '&' },     .{ "quotesingle", '\'' },  .{ "parenleft", '(' },     .{ "parenright", ')' },     .{ "asterisk", '*' },      .{ "plus", '+' },
        .{ "comma", ',' },         .{ "hyphen", '-' },        .{ "minus", 0x2212 },      .{ "period", '.' },         .{ "slash", '/' },         .{ "zero", '0' },
        .{ "one", '1' },           .{ "two", '2' },           .{ "three", '3' },         .{ "four", '4' },           .{ "five", '5' },          .{ "six", '6' },
        .{ "seven", '7' },         .{ "eight", '8' },         .{ "nine", '9' },          .{ "colon", ':' },          .{ "semicolon", ';' },     .{ "less", '<' },
        .{ "equal", '=' },         .{ "greater", '>' },       .{ "question", '?' },      .{ "at", '@' },             .{ "bracketleft", '[' },   .{ "backslash", '\\' },
        .{ "bracketright", ']' },  .{ "asciicircum", '^' },   .{ "underscore", '_' },    .{ "grave", '`' },          .{ "braceleft", '{' },     .{ "bar", '|' },
        .{ "braceright", '}' },    .{ "asciitilde", '~' },    .{ "quoteleft", 0x2018 },  .{ "quoteright", 0x2019 },  .{ "quotedblleft", 0x201C }, .{ "quotedblright", 0x201D },
        .{ "quotedblbase", 0x201E }, .{ "quotesinglbase", 0x201A }, .{ "guillemotleft", 0xAB }, .{ "guillemotright", 0xBB }, .{ "endash", 0x2013 },   .{ "emdash", 0x2014 },
        .{ "ellipsis", 0x2026 },   .{ "bullet", 0x2022 },     .{ "periodcentered", 0xB7 }, .{ "section", 0xA7 },     .{ "copyright", 0xA9 },    .{ "registered", 0xAE },
        .{ "degree", 0xB0 },       .{ "plusminus", 0xB1 },    .{ "multiply", 0xD7 },     .{ "numero", 0x2116 },      .{ "nbspace", ' ' },       .{ "sfthyphen", 0xAD },
        .{ "fi", 0xFB01 },         .{ "fl", 0xFB02 },         .{ "ff", 0xFB00 },         .{ "ffi", 0xFB03 },         .{ "ffl", 0xFB04 },        .{ "dagger", 0x2020 },
        .{ "guilsinglleft", 0x2039 }, .{ "guilsinglright", 0x203A }, .{ "trademark", 0x2122 }, .{ "paragraph", 0xB6 }, .{ "Euro", 0x20AC },       .{ "daggerdbl", 0x2021 },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return null;
}

fn buildFont(d: *Doc, v: Value) Error!*Font {
    const f = try d.a.create(Font);
    f.* = .{};
    try d.budget.take(256);
    const subtype = d.field(v, "Subtype");
    const composite = isName(subtype, "Type0");
    f.two = composite;
    f.plain = !composite;

    // ширины
    if (composite) {
        f.default_width = 1000;
        const desc = d.field(v, "DescendantFonts");
        const cid = if (desc == .array and desc.array.len > 0) d.resolve(desc.array[0]) else Value.null;
        if (cid == .dict) {
            if (get(cid, "DW")) |dw| f.default_width = @floatCast(toNum(d.resolve(dw)));
            const w = d.field(cid, "W");
            if (w == .array) {
                var i: usize = 0;
                const arr = w.array;
                while (i < arr.len) {
                    const c1 = toInt(d.resolve(arr[i])) orelse break;
                    if (i + 1 >= arr.len or c1 < 0 or c1 > 0xFFFF) break;
                    const second = d.resolve(arr[i + 1]);
                    if (second == .array) {
                        for (second.array, 0..) |wv, k| {
                            if (c1 + @as(i64, @intCast(k)) > 0xFFFF) break;
                            try d.budget.take(16);
                            try f.cid_widths.put(d.a, @intCast(c1 + @as(i64, @intCast(k))), @floatCast(toNum(d.resolve(wv))));
                        }
                        i += 2;
                    } else {
                        const c2 = toInt(second) orelse break;
                        if (i + 2 >= arr.len or c2 < c1 or c2 > 0xFFFF) break;
                        const wv: f32 = @floatCast(toNum(d.resolve(arr[i + 2])));
                        var c = c1;
                        while (c <= c2) : (c += 1) {
                            try d.budget.take(16);
                            try f.cid_widths.put(d.a, @intCast(c), wv);
                        }
                        i += 3;
                    }
                }
            }
        }
    } else {
        f.first = std.math.cast(u32, toInt(d.field(v, "FirstChar")) orelse 0) orelse 0;
        const w = d.field(v, "Widths");
        if (w == .array and w.array.len <= 4096) {
            const list = try d.a.alloc(f32, w.array.len);
            for (w.array, list) |wv, *o| o.* = @floatCast(toNum(d.resolve(wv)));
            f.widths = list;
        }
    }

    // имена знаков из /Differences
    const enc = d.field(v, "Encoding");
    if (enc == .dict) {
        const diff = d.field(enc, "Differences");
        if (diff == .array) {
            var code: i64 = 0;
            for (diff.array) |e_raw| {
                const e = d.resolve(e_raw);
                switch (e) {
                    .num => code = toInt(e) orelse 0,
                    .name => |n| {
                        if (code >= 0 and code <= 255) if (glyph(n)) |u| {
                            try d.budget.take(16);
                            try f.map.put(d.a, @intCast(code), common.fromUnicode(u));
                        };
                        code += 1;
                    },
                    else => {},
                }
            }
        }
    }

    // таблица ToUnicode важнее всего остального
    if (get(v, "ToUnicode")) |tu_ref| if (tu_ref == .ref) if (d.objs.get(tu_ref.ref)) |tu| {
        const data = d.decode(tu) catch |err| switch (err) {
            error.Damaged => "",
            else => |e| return e,
        };
        try toUnicode(d, f, data);
    };
    return f;
}

fn toUnicode(d: *Doc, f: *Font, data: []const u8) Error!void {
    var lex = Lex{ .a = d.a, .s = data, .budget = d.budget };
    var src_len: usize = 0;
    var entries: usize = 0;
    const Mode = enum { none, space, char, range };
    var mode: Mode = .none;
    var pending: [3]Value = undefined;
    var n: usize = 0;
    while (true) {
        const before = lex.i;
        const v = (lex.value(0) catch |err| switch (err) {
            error.Damaged => break,
            else => |e| return e,
        }) orelse {
            if (lex.i >= data.len) break;
            if (lex.i == before) lex.i += 1;
            continue;
        };
        try d.spend(1);
        if (v == .op) {
            mode = if (std.mem.eql(u8, v.op, "begincodespacerange")) .space else if (std.mem.eql(u8, v.op, "beginbfchar")) .char else if (std.mem.eql(u8, v.op, "beginbfrange")) .range else .none;
            n = 0;
            continue;
        }
        if (mode == .none) continue;
        pending[n] = v;
        n += 1;
        switch (mode) {
            .space => if (n == 2) {
                n = 0;
                if (pending[0] == .str) src_len = @max(src_len, pending[0].str.len);
            },
            .char => if (n == 2) {
                n = 0;
                if (pending[0] != .str or pending[1] != .str) continue;
                src_len = @max(src_len, pending[0].str.len);
                entries += 1;
                if (entries > 300_000) return;
                try d.budget.take(24);
                try f.map.put(d.a, codeOf(pending[0].str), try utf16ToCp(d.a, pending[1].str, 0));
            },
            .range => if (n == 3) {
                n = 0;
                if (pending[0] != .str or pending[1] != .str) continue;
                src_len = @max(src_len, pending[0].str.len);
                const lo = codeOf(pending[0].str);
                const hi = codeOf(pending[1].str);
                if (hi < lo or hi - lo > 0xFFFF) continue;
                var c = lo;
                while (true) : (c += 1) {
                    entries += 1;
                    if (entries > 300_000) return;
                    const dst: ?[]const u8 = switch (pending[2]) {
                        .str => |s| try utf16ToCp(d.a, s, c - lo),
                        .array => |arr| if (c - lo < arr.len and arr[c - lo] == .str) try utf16ToCp(d.a, arr[c - lo].str, 0) else null,
                        else => null,
                    };
                    if (dst) |t| {
                        try d.budget.take(24);
                        try f.map.put(d.a, c, t);
                    }
                    if (c == hi) break;
                }
            },
            .none => {},
        }
    }
    if (src_len >= 2) f.two = true;
    if (src_len == 1) f.two = false;
}

fn fontFor(d: *Doc, resources: Value, name: []const u8) Error!?*Font {
    const fonts = d.field(resources, "Font");
    const entry = get(fonts, name) orelse return null;
    if (entry == .ref) {
        if (d.fonts.get(entry.ref)) |f| return f;
        const v = d.resolve(entry);
        if (v != .dict) return null;
        const f = try buildFont(d, v);
        try d.fonts.put(d.a, entry.ref, f);
        return f;
    }
    if (entry != .dict) return null;
    return try buildFont(d, entry);
}

// ───────────── содержимое страницы ─────────────

const M = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    /// Сначала `m`, потом `n`.
    fn mul(m: M, n: M) M {
        return .{
            .a = m.a * n.a + m.b * n.c,
            .b = m.a * n.b + m.b * n.d,
            .c = m.c * n.a + m.d * n.c,
            .d = m.c * n.b + m.d * n.d,
            .e = m.e * n.a + m.f * n.c + n.e,
            .f = m.e * n.b + m.f * n.d + n.f,
        };
    }

    fn from(args: []const Value) ?M {
        if (args.len < 6) return null;
        const s = args[args.len - 6 ..];
        return .{ .a = toNum(s[0]), .b = toNum(s[1]), .c = toNum(s[2]), .d = toNum(s[3]), .e = toNum(s[4]), .f = toNum(s[5]) };
    }
};

pub const Line = struct {
    x0: f64,
    x1: f64,
    y: f64,
    size: f64,
    text: std.ArrayListUnmanaged(u8) = .{},
    /// номер страницы с нуля
    page: u32 = 0,
};

const Page = struct {
    d: *Doc,
    lines: *std.ArrayListUnmanaged(Line),
    cur: ?Line = null,
    index: u32 = 0,

    fn flushLine(p: *Page) Error!void {
        if (p.cur) |l| {
            var line = l;
            line.page = p.index;
            const t = std.mem.trim(u8, line.text.items, " ");
            if (t.len > 0) {
                line.text.items = @constCast(t);
                try p.lines.append(p.d.a, line);
            }
        }
        p.cur = null;
    }

    /// Знак (или несколько) в точке (x, y) устройства; `w` — его ширина там же.
    fn put(p: *Page, x: f64, y: f64, size: f64, w: f64, t: []const u8) Error!void {
        if (p.cur) |*l| {
            const s = @max(@max(size, l.size), 0.01);
            const dy = @abs(y - l.y);
            const gap = x - l.x1;
            if (!(dy <= 0.5 * s) or !(gap >= -2.0 * s)) {
                try p.flushLine(); // другая строка (или возврат далеко влево — колонка)
            } else if (gap > 0.2 * s and l.text.items.len > 0 and l.text.items[l.text.items.len - 1] != ' ' and !(t.len > 0 and t[0] == ' ')) {
                try l.text.append(p.d.a, ' ');
            }
        }
        if (p.cur == null) p.cur = .{ .x0 = x, .x1 = x, .y = y, .size = size };
        const l = &p.cur.?;
        try p.d.budget.take(t.len + 1);
        for (t) |c| {
            const ch: u8 = if (c == '\n' or c == '\r' or c == '\t' or c == 0xA0) ' ' else c;
            if (ch == ' ' and (l.text.items.len == 0 or l.text.items[l.text.items.len - 1] == ' ')) continue;
            if (ch < 0x20) continue;
            try l.text.append(p.d.a, ch);
        }
        l.x1 = x + w;
        if (size > l.size) l.size = size;
    }
};

const State = struct {
    ctm: M = .{},
    tm: M = .{},
    tlm: M = .{},
    font: ?*Font = null,
    fs: f64 = 0,
    tc: f64 = 0,
    tw: f64 = 0,
    th: f64 = 1,
    tl: f64 = 0,
};

fn show(p: *Page, st: *State, s: []const u8) Error!void {
    const d = p.d;
    const f = st.font orelse return;
    const m = st.tm.mul(st.ctm);
    const unit = std.math.hypot(m.a, m.b); // длина единицы текста на устройстве
    const size = @abs(st.fs) * std.math.sqrt(@abs(m.a * m.d - m.b * m.c));
    var adv: f64 = 0;
    const step: usize = if (f.two) 2 else 1;
    var i: usize = 0;
    try d.spend(s.len);
    while (i + step <= s.len) : (i += step) {
        const code: u32 = if (f.two) (@as(u32, s[i]) << 8) | s[i + 1] else s[i];
        const w = (f.width(code) / 1000.0 * st.fs + st.tc + (if (!f.two and code == 32) st.tw else 0)) * st.th;
        d.glyphs += 1;
        const t = f.text(code) orelse blk: {
            d.unknown += 1;
            break :blk "?";
        };
        try p.put(m.e + adv * m.a, m.f + adv * m.b, size, w * unit, t);
        adv += w;
    }
    st.tm.e += adv * st.tm.a;
    st.tm.f += adv * st.tm.b;
}

fn content(p: *Page, data: []const u8, resources: Value, ctm: M, depth: usize) Error!void {
    const d = p.d;
    var lex = Lex{ .a = d.a, .s = data, .budget = d.budget };
    var args = std.ArrayList(Value).init(d.a);
    var st = State{ .ctm = ctm };
    var stack = std.ArrayList(M).init(d.a);
    while (true) {
        const before = lex.i;
        const v = (lex.value(0) catch |err| switch (err) {
            error.Damaged => break,
            else => |e| return e,
        }) orelse {
            if (lex.i >= data.len) break;
            if (lex.i == before) lex.i += 1;
            continue;
        };
        if (v != .op) {
            if (args.items.len < 64) try args.append(v);
            continue;
        }
        try d.spend(1);
        const op = v.op;
        const a = args.items;
        const n = a.len;
        if (std.mem.eql(u8, op, "Tj")) {
            if (n >= 1 and a[n - 1] == .str) try show(p, &st, a[n - 1].str);
        } else if (std.mem.eql(u8, op, "TJ")) {
            if (n >= 1 and a[n - 1] == .array) for (a[n - 1].array) |e| switch (e) {
                .str => |s| try show(p, &st, s),
                .num => |x| {
                    const tx = -x / 1000.0 * st.fs * st.th;
                    st.tm.e += tx * st.tm.a;
                    st.tm.f += tx * st.tm.b;
                },
                else => {},
            };
        } else if (std.mem.eql(u8, op, "Td") or std.mem.eql(u8, op, "TD")) {
            if (n >= 2) {
                const tx = toNum(a[n - 2]);
                const ty = toNum(a[n - 1]);
                if (op[1] == 'D') st.tl = -ty;
                st.tlm = (M{ .e = tx, .f = ty }).mul(st.tlm);
                st.tm = st.tlm;
            }
        } else if (std.mem.eql(u8, op, "Tm")) {
            if (M.from(a)) |m| {
                st.tlm = m;
                st.tm = m;
            }
        } else if (std.mem.eql(u8, op, "T*") or std.mem.eql(u8, op, "'") or std.mem.eql(u8, op, "\"")) {
            if (op[0] == '"' and n >= 3) {
                st.tw = toNum(a[n - 3]);
                st.tc = toNum(a[n - 2]);
            }
            st.tlm = (M{ .e = 0, .f = -st.tl }).mul(st.tlm);
            st.tm = st.tlm;
            if (op[0] != 'T' and n >= 1 and a[n - 1] == .str) try show(p, &st, a[n - 1].str);
        } else if (std.mem.eql(u8, op, "Tf")) {
            if (n >= 2 and a[n - 2] == .name) {
                st.font = try fontFor(d, resources, a[n - 2].name);
                st.fs = toNum(a[n - 1]);
            }
        } else if (std.mem.eql(u8, op, "BT")) {
            st.tm = .{};
            st.tlm = .{};
        } else if (std.mem.eql(u8, op, "Tc")) {
            if (n >= 1) st.tc = toNum(a[n - 1]);
        } else if (std.mem.eql(u8, op, "Tw")) {
            if (n >= 1) st.tw = toNum(a[n - 1]);
        } else if (std.mem.eql(u8, op, "Tz")) {
            if (n >= 1) st.th = toNum(a[n - 1]) / 100.0;
        } else if (std.mem.eql(u8, op, "TL")) {
            if (n >= 1) st.tl = toNum(a[n - 1]);
        } else if (std.mem.eql(u8, op, "cm")) {
            if (M.from(a)) |m| st.ctm = m.mul(st.ctm);
        } else if (std.mem.eql(u8, op, "q")) {
            if (stack.items.len < 256) try stack.append(st.ctm);
        } else if (std.mem.eql(u8, op, "Q")) {
            if (stack.items.len > 0) st.ctm = stack.pop().?;
        } else if (std.mem.eql(u8, op, "Do")) {
            if (n >= 1 and a[n - 1] == .name and depth < max_form_depth) {
                const xo = get(d.field(resources, "XObject"), a[n - 1].name);
                if (xo != null and xo.? == .ref) if (d.objs.get(xo.?.ref)) |form| {
                    if (isName(get(form.val, "Subtype"), "Form")) {
                        const inner = d.decode(form) catch |err| switch (err) {
                            error.Damaged => "",
                            else => |e| return e,
                        };
                        const res = d.field(form.val, "Resources");
                        const fm = d.field(form.val, "Matrix");
                        const base = if (fm == .array) (M.from(fm.array) orelse M{}).mul(st.ctm) else st.ctm;
                        try content(p, inner, if (res == .dict) res else resources, base, depth + 1);
                    }
                };
            }
        } else if (std.mem.eql(u8, op, "BI")) {
            // встроенная картинка: до «EI» идут сырые байты
            const id = std.mem.indexOfPos(u8, data, lex.i, "ID") orelse data.len;
            var e = id;
            while (std.mem.indexOfPos(u8, data, e, "EI")) |k| {
                e = k + 2;
                if (k > 0 and isWs(data[k - 1]) and (e >= data.len or isWs(data[e]))) break;
            } else e = data.len;
            lex.i = @min(data.len, e);
        }
        args.clearRetainingCapacity();
    }
}

// ───────────── строки → абзацы ─────────────

fn endsSentence(t: []const u8) bool {
    if (t.len == 0) return true;
    return switch (t[t.len - 1]) {
        '.', '!', '?', ':', ';', '"', ')', 0x85, 0xBB, 0x93, 0x94 => true,
        else => false,
    };
}

fn isLower(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c >= 0xE0 or c == 0xB8 or c == 0xB3 or c == 0xBF or c == 0xBA;
}
fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0xC0 or c == 0xB8 or c == 0xA8 or c == 0xB3 or c == 0xB2 or c == 0xBF or c == 0xAF or c == 0xBA or c == 0xAA;
}

/// Номер страницы или колонтитул из одних цифр.
fn isPageNumber(t: []const u8) bool {
    if (t.len > 10) return false;
    var digits: usize = 0;
    for (t) |c| switch (c) {
        '0'...'9' => digits += 1,
        ' ', '-', 0x96, 0x97, '.', '[', ']' => {},
        else => return false,
    };
    return digits > 0;
}

/// Обычный шаг между строками страницы: медиана.
fn pageLead(a: std.mem.Allocator, page: []const Line) common.Error!f64 {
    if (page.len < 2) return 0;
    var steps = std.ArrayList(f64).init(a);
    for (page[1..], page[0 .. page.len - 1]) |l, p| {
        const dy = @abs(l.y - p.y);
        if (dy > 0.3 * l.size and dy < 3 * @max(l.size, 0.01)) try steps.append(dy);
    }
    if (steps.items.len == 0) return 0;
    std.mem.sort(f64, steps.items, {}, std.sort.asc(f64));
    return steps.items[steps.items.len / 2];
}

fn pageEnd(lines: []const Line, from: usize) usize {
    var to = from + 1;
    while (to < lines.len and lines[to].page == lines[from].page) to += 1;
    return to;
}

/// Убирает колонтитулы: крайнюю строку страницы, которая (без цифр) повторяется
/// на многих страницах и стоит от текста дальше обычного шага строк.
pub fn stripRunning(a: std.mem.Allocator, lines_in: []Line, n_pages: usize) common.Error![]Line {
    var lines = lines_in;
    // не меньше 40% страниц: заголовки глав («Глава 7») тоже стоят вверху страницы и
    // тоже похожи друг на друга, но их мало
    const need = @max(3, (n_pages * 2 + 4) / 5);
    var round: usize = 0;
    while (round < 2 and lines.len > 0) : (round += 1) {
        const Key = struct {
            fn of(al: std.mem.Allocator, t: []const u8) common.Error![]const u8 {
                const k = try al.alloc(u8, t.len);
                var n: usize = 0;
                for (t) |c| if (!(c >= '0' and c <= '9') and c != ' ') {
                    k[n] = c;
                    n += 1;
                };
                return k[0..n];
            }
        };
        var top = std.StringHashMap(u32).init(a);
        var bottom = std.StringHashMap(u32).init(a);
        var from: usize = 0;
        while (from < lines.len) {
            const to = pageEnd(lines, from);
            if (to - from >= 2) {
                inline for (.{ .{ &top, from }, .{ &bottom, to - 1 } }) |e| {
                    const k = try Key.of(a, lines[e[1]].text.items);
                    if (k.len > 0) {
                        const gop = try e[0].getOrPut(k);
                        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                    }
                }
            }
            from = to;
        }
        var kept: usize = 0;
        var dropped = false;
        from = 0;
        while (from < lines.len) {
            const to = pageEnd(lines, from);
            const lead = try pageLead(a, lines[from..to]);
            for (from..to) |i| {
                var drop = false;
                if (to - from >= 2 and (i == from or i == to - 1)) {
                    const k = try Key.of(a, lines[i].text.items);
                    const count = (if (i == from) top.get(k) else bottom.get(k)) orelse 0;
                    const neighbour = if (i == from) lines[i + 1] else lines[i - 1];
                    const gap = @abs(lines[i].y - neighbour.y);
                    drop = k.len > 0 and count >= need and (lead == 0 or gap > 1.25 * lead);
                }
                if (drop) {
                    dropped = true;
                } else {
                    lines[kept] = lines[i];
                    kept += 1;
                }
            }
            from = to;
        }
        lines = lines[0..kept];
        if (!dropped) break;
    }
    return lines;
}

pub fn paragraphs(a: std.mem.Allocator, lines: []const Line, budget: *Budget) common.Error![]const u8 {
    var out = std.ArrayList(u8).init(a);
    // поля и шаг строк считаются по каждой странице
    var from: usize = 0;
    var prev: ?Line = null;
    var prev_short = false;
    while (from < lines.len) {
        const to = pageEnd(lines, from);
        const page = lines[from..to];
        var left: f64 = std.math.inf(f64);
        var right: f64 = -std.math.inf(f64);
        for (page) |l| {
            if (l.text.items.len < 20) continue; // поля — по настоящим строкам, не по заголовкам
            left = @min(left, l.x0);
            right = @max(right, l.x1);
        }
        if (!(left < right)) for (page) |l| {
            left = @min(left, l.x0);
            right = @max(right, l.x1);
        };
        const lead = try pageLead(a, page);

        // стихи: почти все строки страницы не доходят до правого поля —
        // тогда каждая строка остаётся отдельной
        var short_lines: usize = 0;
        var counted: usize = 0;
        for (page) |l| {
            if (isPageNumber(l.text.items)) continue;
            counted += 1;
            if (l.x1 < right - 3 * l.size) short_lines += 1;
        }
        const verse = counted >= 4 and short_lines * 5 >= counted * 3;
        var first = true; // первая оставленная строка страницы
        for (page, 0..) |l, i| {
            const t = l.text.items;
            if (isPageNumber(t) and (i == 0 or i + 1 == page.len or i < 2)) continue;
            const indent = l.x0 > left + 0.6 * l.size;
            var brk = true;
            if (verse) {
                // строки стихов не склеиваются
            } else if (prev) |p| {
                if (first) {
                    // через границу страницы абзац продолжается, если фраза не кончилась
                    brk = endsSentence(p.text.items) and (indent or prev_short);
                } else {
                    const dy = @abs(l.y - p.y);
                    brk = (lead > 0 and dy > 1.45 * lead) or (indent and !(p.x0 > left + 0.6 * p.size)) or (prev_short and endsSentence(p.text.items)) or @abs(l.size - p.size) > 0.2 * @max(l.size, p.size);
                }
            }
            try budget.take(t.len + 2);
            if (out.items.len == 0) {
                // первая строка
            } else if (brk) {
                try out.appendSlice("\n\n");
            } else {
                const o = out.items;
                const hyphen = o[o.len - 1] == '-' or o[o.len - 1] == 0xAD;
                if (hyphen and o.len >= 2 and isLetter(o[o.len - 2]) and t.len > 0 and isLower(t[0])) {
                    out.items.len -= 1; // перенос слова
                } else if (o[o.len - 1] == 0xAD) {
                    out.items.len -= 1;
                } else try out.append(' ');
            }
            try out.appendSlice(t);
            first = false;
            prev = l;
            prev_short = l.x1 < right - 3 * l.size;
        }
        from = to;
    }
    return out.items;
}

// ───────────── книга ─────────────

/// Строка PDF (название, пункт оглавления) → windows-1251.
fn textString(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (s.len >= 2 and s[0] == 0xFE and s[1] == 0xFF) return utf16ToCp(a, s[2..], 0);
    var raw = s;
    if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw = raw[3..];
    const text = if (cp.looksUtf8(raw) and std.mem.indexOfNone(u8, raw, &ascii_all) != null) try cp.encodeAlloc(a, raw) else try a.dupe(u8, raw);
    for (text) |*c| if (c.* < 0x20) {
        c.* = ' ';
    };
    return std.mem.trim(u8, text, " ");
}

const ascii_all: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = i;
    break :blk t;
};

const PageRef = struct { num: u32, val: Value, resources: Value };

fn collectPages(d: *Doc, out: *std.ArrayList(PageRef)) Error!void {
    var root = d.resolve(d.root);
    if (root != .dict or get(root, "Pages") == null) {
        // каталога нет в хвосте файла: ищем его среди объектов
        var it = d.objs.iterator();
        while (it.next()) |e| if (isName(get(e.value_ptr.val, "Type"), "Catalog")) {
            root = e.value_ptr.val;
            d.root = root;
            break;
        };
    }
    const Frame = struct { ref: Value, resources: Value };
    var stack = std.ArrayList(Frame).init(d.a);
    var seen = std.AutoHashMap(u32, void).init(d.a);
    if (get(root, "Pages")) |pages| try stack.append(.{ .ref = pages, .resources = .null });
    while (stack.pop()) |fr| {
        try d.spend(1);
        if (fr.ref == .ref) {
            if (seen.contains(fr.ref.ref)) continue;
            try seen.put(fr.ref.ref, {});
        }
        const node = d.resolve(fr.ref);
        if (node != .dict) continue;
        const own = d.field(node, "Resources");
        const res = if (own == .dict) own else fr.resources;
        const kids = d.field(node, "Kids");
        if (kids == .array and !isName(get(node, "Type"), "Page")) {
            // стек: дети кладутся в обратном порядке, чтобы выйти в прямом
            var k = kids.array.len;
            while (k > 0) : (k -= 1) try stack.append(.{ .ref = kids.array[k - 1], .resources = res });
        } else if (get(node, "Contents") != null or isName(get(node, "Type"), "Page")) {
            if (out.items.len >= max_pages) return error.TooBig;
            try out.append(.{ .num = if (fr.ref == .ref) fr.ref.ref else 0, .val = node, .resources = res });
        }
    }
    if (out.items.len == 0) {
        // дерево страниц не читается: страницы по порядку номеров объектов
        var nums = std.ArrayList(u32).init(d.a);
        var it = d.objs.iterator();
        while (it.next()) |e| if (isName(get(e.value_ptr.val, "Type"), "Page")) try nums.append(e.key_ptr.*);
        std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));
        for (nums.items[0..@min(nums.items.len, max_pages)]) |num| {
            const v = d.objs.get(num).?.val;
            try out.append(.{ .num = num, .val = v, .resources = d.field(v, "Resources") });
        }
    }
}

const Mark = struct { page: usize, title: []const u8 };

/// Верхний уровень оглавления: страница и название каждого пункта.
fn outline(d: *Doc, pages: []const PageRef) Error![]const Mark {
    var marks = std.ArrayList(Mark).init(d.a);
    const root = d.resolve(d.root);
    var level = d.field(root, "Outlines");
    var tries: usize = 0;
    while (tries < 2) : (tries += 1) {
        marks.clearRetainingCapacity();
        var item = get(level, "First");
        var seen = std.AutoHashMap(u32, void).init(d.a);
        var first_child: ?Value = null;
        var count: usize = 0;
        while (item) |it_ref| {
            if (it_ref != .ref or seen.contains(it_ref.ref) or count > 5000) break;
            try seen.put(it_ref.ref, {});
            count += 1;
            const it = d.resolve(it_ref);
            if (it != .dict) break;
            if (first_child == null) first_child = it;
            var dest = d.resolve(get(it, "Dest"));
            if (dest == .null) dest = d.field(d.field(it, "A"), "D");
            if (dest == .name or dest == .str) {
                // именованное назначение — только из простого словаря /Dests
                const named = d.field(d.field(root, "Dests"), if (dest == .name) dest.name else dest.str);
                dest = if (named == .dict) d.field(named, "D") else named;
            }
            if (dest == .array and dest.array.len > 0 and dest.array[0] == .ref) {
                const target = dest.array[0].ref;
                for (pages, 0..) |pg, i| if (pg.num == target) {
                    const title = d.field(it, "Title");
                    var t = if (title == .str) try textString(d.a, title.str) else "";
                    if (t.len > 200) t = t[0..200];
                    if (t.len > 0) try marks.append(.{ .page = i, .title = t });
                    break;
                };
            }
            item = get(it, "Next");
        }
        // единственный пункт верхнего уровня — обычно название книги: главы под ним
        if (count == 1 and first_child != null and get(first_child.?, "First") != null) {
            level = first_child.?;
            continue;
        }
        break;
    }
    std.mem.sort(Mark, marks.items, {}, struct {
        fn lt(_: void, x: Mark, y: Mark) bool {
            return x.page < y.page;
        }
    }.lt);
    return marks.items;
}

pub fn looksLike(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes[0..@min(bytes.len, 1024)], "%PDF-") != null;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, budget: *Budget) Error!Parsed {
    if (!looksLike(bytes)) return error.NotPdf;
    var d = Doc{ .a = a, .bytes = bytes, .budget = budget };
    try d.scan();
    if (d.encrypted) return error.Encrypted;
    try d.expandObjectStreams();

    var pages = std.ArrayList(PageRef).init(a);
    try collectPages(&d, &pages);
    if (pages.items.len == 0) return error.NotPdf;

    // строки всех страниц подряд
    var all = std.ArrayListUnmanaged(Line){};
    for (pages.items, 0..) |pg, i| {
        var page = Page{ .d = &d, .lines = &all, .index = @intCast(i) };
        const contents = d.resolve(get(pg.val, "Contents"));
        const one = [1]Value{get(pg.val, "Contents") orelse .null};
        const parts: []const Value = if (contents == .array) contents.array else &one;
        // части содержимого — один поток: операторы могут быть разрезаны между ними
        var joined = std.ArrayList(u8).init(a);
        for (parts) |part| {
            if (part != .ref) continue;
            const obj = d.objs.get(part.ref) orelse continue;
            const data = d.decode(obj) catch |err| switch (err) {
                error.Damaged => continue,
                else => |e| return e,
            };
            try budget.take(data.len + 1);
            try joined.appendSlice(data);
            try joined.append('\n');
        }
        try content(&page, joined.items, pg.resources, .{}, 0);
        try page.flushLine();
    }
    // текстового слоя нет (скан) или буквы не переводятся (шрифт без таблицы)
    var letters: usize = 0;
    for (all.items) |l| letters += l.text.items.len;
    if (letters < 200 or letters < 40 * pages.items.len) return error.NoText;
    if (d.glyphs > 0 and d.unknown * 5 > d.glyphs) return error.Garbled;

    var out = Parsed{};
    const info = d.resolve(d.info);
    if (info == .dict) {
        const title = d.field(info, "Title");
        if (title == .str) out.title = try textString(a, title.str);
        const author = d.field(info, "Author");
        if (author == .str) out.author = try textString(a, author.str);
        inline for (.{ "Microsoft Word - ", "Microsoft PowerPoint - " }) |junk| {
            if (std.mem.startsWith(u8, out.title, junk)) out.title = out.title[junk.len..];
        }
        if (std.ascii.eqlIgnoreCase(out.title, "untitled")) out.title = "";
        if (out.title.len > 300) out.title = out.title[0..300];
        if (out.author.len > 200) out.author = out.author[0..200];
    }

    const lines = try stripRunning(a, all.items, pages.items.len);
    // где начинаются строки каждой страницы
    const starts = try a.alloc(usize, pages.items.len + 1);
    {
        var at: usize = 0;
        for (starts[0..pages.items.len], 0..) |*st, i| {
            while (at < lines.len and lines[at].page < i) at += 1;
            st.* = at;
        }
        starts[pages.items.len] = lines.len;
    }

    var chapters = std.ArrayList(Chapter).init(a);
    const marks = try outline(&d, pages.items);
    var uniq = std.ArrayList(Mark).init(a);
    for (marks) |m| if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1].page != m.page) try uniq.append(m);
    if (uniq.items.len >= 2) {
        if (uniq.items[0].page > 0) try uniq.insert(0, .{ .page = 0, .title = cp.text("Начало") });
        for (uniq.items, 0..) |m, i| {
            const end = if (i + 1 < uniq.items.len) uniq.items[i + 1].page else pages.items.len;
            const text = try paragraphs(a, lines[starts[m.page]..starts[end]], budget);
            if (text.len > 0) try chapters.append(.{ .title = m.title, .text = text });
        }
    } else {
        const text = try paragraphs(a, lines, budget);
        if (text.len > 0) try chapters.append(.{ .title = cp.text("Текст"), .text = text });
    }
    if (chapters.items.len == 0) return error.NoText;
    out.chapters = chapters.items;
    return out;
}
