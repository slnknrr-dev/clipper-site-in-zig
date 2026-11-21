//! Песни в ChordPro (BACKLOG_RU.md §20): аккорды в квадратных скобках прямо в словах —
//! «[Am]Ночь, бен[Dm]зин и ветер». Директивы: {title}/{t}, {subtitle}/{st},
//! {comment}/{c}/{ci}, {start_of_chorus}/{soc} … {end_of_chorus}/{eoc}; прочие
//! пропускаются. Пустая строка — граница куплета.
//!
//! Показ — средствами до 2003 года: строка с аккордами — маленькая таблица в две
//! строки, ячейка на кусок слов, аккорд над своим слогом при любом шрифте. Ни
//! CSS3, ни JavaScript; работает в IE5 и Netscape 6. Текст — windows-1251.

const std = @import("std");
const W = @import("out.zig").W;

/// Похоже ли на ChordPro: есть аккорд в скобках или директива.
pub fn looksLike(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len > 2 and line[0] == '{' and line[line.len - 1] == '}') return true;
        if (std.mem.indexOfScalar(u8, line, '[')) |o| if (std.mem.indexOfScalarPos(u8, line, o, ']')) |c| if (c > o + 1 and c - o <= 12) return true;
    }
    return false;
}

const Directive = struct { name: []const u8, value: []const u8 };

fn directive(line: []const u8) ?Directive {
    if (line.len < 2 or line[0] != '{' or line[line.len - 1] != '}') return null;
    const body = line[1 .. line.len - 1];
    const colon = std.mem.indexOfScalar(u8, body, ':');
    const name = std.mem.trim(u8, if (colon) |c| body[0..c] else body, " ");
    const value = if (colon) |c| std.mem.trim(u8, body[c + 1 ..], " ") else "";
    return .{ .name = name, .value = value };
}

fn is(name: []const u8, comptime long: []const u8, comptime short: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, long) or std.ascii.eqlIgnoreCase(name, short);
}

/// Слова без аккордов — для поиска, выгрузки и начала песни в списках.
pub fn lyrics(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \r\t");
        if (directive(std.mem.trim(u8, line, " \t")) != null) continue;
        if (!first) out.append('\n') catch break;
        first = false;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '[') if (std.mem.indexOfScalarPos(u8, line, i, ']')) |c| {
                i = c + 1;
                continue;
            };
            out.append(line[i]) catch break;
            i += 1;
        }
    }
    return out.items;
}

/// Строка слов с аккордами → таблица «аккорды над словами».
fn chordLine(w: *W, line: []const u8) void {
    // куски: (аккорд, слова до следующего аккорда)
    w.raw("<table class=\"cp\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\"><tr>");
    const Seg = struct { chord: []const u8, text: []const u8 };
    var segs: [64]Seg = undefined;
    var n: usize = 0;
    var chord: []const u8 = "";
    var start: usize = 0;
    var i: usize = 0;
    while (true) {
        // следующий аккорд «[...]» или конец строки
        var next: ?usize = null;
        var k = i;
        while (k < line.len) : (k += 1) if (line[k] == '[' and std.mem.indexOfScalarPos(u8, line, k, ']') != null) {
            next = k;
            break;
        };
        const end = next orelse line.len;
        if (n + 1 == segs.len) {
            // слишком много аккордов: остаток строки — одним куском
            segs[n] = .{ .chord = chord, .text = line[start..] };
            n += 1;
            break;
        }
        if (end > start or chord.len > 0) {
            segs[n] = .{ .chord = chord, .text = line[start..end] };
            n += 1;
        }
        const o = next orelse break;
        const c = std.mem.indexOfScalarPos(u8, line, o, ']').?;
        chord = line[o + 1 .. c];
        i = c + 1;
        start = i;
    }
    for (segs[0..n]) |s| {
        w.raw("<td class=\"ch\" valign=\"bottom\" nowrap>");
        if (s.chord.len > 0) w.f("<b>{h}</b>&nbsp;", .{s.chord}) else w.raw("&nbsp;");
        w.raw("</td>");
    }
    w.raw("</tr><tr>");
    for (segs[0..n]) |s| {
        w.raw("<td nowrap>");
        // пробелы видны: подряд идущие не схлопываются
        var k: usize = 0;
        while (k < s.text.len) : (k += 1) {
            if (s.text[k] == ' ') w.raw("&nbsp;") else w.esc(s.text[k .. k + 1]);
        }
        if (s.text.len == 0) w.raw("&nbsp;");
        w.raw("</td>");
    }
    w.raw("</tr></table>\n");
}

/// Песня целиком.
pub fn render(w: *W, text: []const u8) void {
    renderIds(w, text, false);
}

/// С якорями куплетов p0, p1, … (как абзацы слов в `lyrics`) — для цитат.
pub fn renderIds(w: *W, text: []const u8, ids: bool) void {
    w.raw(if (ids) "<div class=\"song\" id=\"booktext\">\n" else "<div class=\"song\">\n");
    var chorus = false;
    var stanza: usize = 0;
    var open = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \r\t");
        const t = std.mem.trim(u8, line, " \t");
        if (directive(t)) |d| {
            if (is(d.name, "title", "t")) {
                w.f("<h3>{h}</h3>\n", .{d.value});
            } else if (is(d.name, "subtitle", "st")) {
                w.f("<div class=\"muted\">{h}</div>\n", .{d.value});
            } else if (is(d.name, "comment", "c") or is(d.name, "comment_italic", "ci")) {
                w.f("<div><i>{h}</i></div>\n", .{d.value});
            } else if (is(d.name, "start_of_chorus", "soc") and !chorus) {
                chorus = true;
                w.raw("<blockquote class=\"chorus\">\n");
            } else if (is(d.name, "end_of_chorus", "eoc") and chorus) {
                chorus = false;
                w.raw("</blockquote>\n");
            }
            continue;
        }
        if (t.len == 0) {
            if (open) {
                w.raw("</div>");
                open = false;
                stanza += 1;
            }
            w.raw("<br>\n");
            continue;
        }
        if (ids and !open) {
            w.f("<div id=\"p{d}\"><a name=\"p{d}\"></a>", .{ stanza, stanza });
            open = true;
        }
        if (std.mem.indexOfScalar(u8, line, '[') != null) {
            chordLine(w, line);
        } else {
            w.f("<div>{h}</div>\n", .{line});
        }
    }
    if (open) w.raw("</div>");
    if (chorus) w.raw("</blockquote>\n");
    w.raw("</div>\n");
}

test "chordpro: аккорды над словами, директивы, слова без аккордов" {
    var buf: [8192]u8 = undefined;
    var w = W.init(&buf);
    const song = "{title: Вальс}\n{c: медленно}\n[Am]Ночь, бен[Dm]зин и ветер\nбез аккордов\n\n{soc}\n[G]Кто [C]за всё\n{eoc}\n{unknown: x}";
    render(&w, song);
    const html = w.out();
    try std.testing.expect(std.mem.indexOf(u8, html, "<h3>Вальс</h3>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<i>медленно</i>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<b>Am</b>&nbsp;</td><td class=\"ch\" valign=\"bottom\" nowrap><b>Dm</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<blockquote class=\"chorus\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div>без аккордов</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "unknown") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Ночь, бензин и ветер\nбез аккордов\n\nКто за всё", lyrics(arena.allocator(), song));
    try std.testing.expect(looksLike(song));
    try std.testing.expect(!looksLike("просто стих\n[сноска нет]"));
    // враждебное: незакрытые скобки, сотни аккордов в строке
    var big: [4000]u8 = undefined;
    for (0..1000) |k| @memcpy(big[k * 4 ..][0..4], "[A]x");
    var w2buf: [200_000]u8 = undefined;
    var w2 = W.init(&w2buf);
    render(&w2, &big);
    render(&w2, "[[[ ]]] [ [A");
}
