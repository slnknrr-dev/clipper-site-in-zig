//! SVG → RGBA8 своим растеризатором (BACKLOG_RU.md §19). Векторная картинка
//! отрисовывается в своём размере (вписанном в место, без увеличения) и дальше
//! хранится PNG.
//!
//! Берётся: path (все команды, дуги), rect (скругления), circle, ellipse, line,
//! polyline, polygon; g, svg (вложенные — с viewBox), use и symbol, defs;
//! transform; fill (nonzero и evenodd), stroke (ширина, концы, соединения
//! miter/round/bevel, пунктир); opacity, fill-opacity, stroke-opacity; цвета
//! (#rgb, #rrggbb, rgb(), имена CSS, currentColor); линейные и радиальные
//! градиенты (с href, pad/reflect/repeat); простые правила <style> (тег, .класс,
//! #id). Не берётся: текст, картинки, фильтры, маски, обрезка, узоры.
//!
//! Вход не доверяется: сущности DOCTYPE не раскрываются, глубина, число узлов,
//! точек и ссылок use ограничены.

const std = @import("std");
const Image = @import("image.zig").Image;

pub const Error = error{ NotSvg, Damaged, TooBig, OutOfMemory };

const max_nodes = 200_000;
const max_depth = 256;
const max_points = 4_000_000;
const max_use_depth = 12;

/// Дробное → целое в [lo, hi]; NaN и бесконечности — к краю.
fn toInt(v: f32, lo: usize, hi: usize) usize {
    if (!(v >= @as(f32, @floatFromInt(lo)))) return lo;
    if (!(v <= @as(f32, @floatFromInt(hi)))) return hi;
    return @intFromFloat(v);
}

// ───────────── XML ─────────────

const Attr = struct { name: []const u8, value: []const u8 };

const Node = struct {
    name: []const u8,
    attrs: []Attr,
    kids: std.ArrayListUnmanaged(u32) = .{},
    parent: u32,
};

const Doc = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .{},
    css: std.ArrayListUnmanaged(u8) = .{},
    ids: std.StringHashMapUnmanaged(u32) = .{},

    fn attr(d: *const Doc, n: u32, name: []const u8) ?[]const u8 {
        for (d.nodes.items[n].attrs) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
        return null;
    }
};

fn localName(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, ':')) |c| s[c + 1 ..] else s;
}

fn decodeEntities(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |e| if (e - i <= 10) {
            const name = s[i + 1 .. e];
            var cp: ?u21 = null;
            if (std.mem.eql(u8, name, "amp")) cp = '&' else if (std.mem.eql(u8, name, "lt")) cp = '<' else if (std.mem.eql(u8, name, "gt")) cp = '>' else if (std.mem.eql(u8, name, "quot")) cp = '"' else if (std.mem.eql(u8, name, "apos")) cp = '\'' else if (name.len > 1 and name[0] == '#') {
                cp = if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) catch null else std.fmt.parseInt(u21, name[1..], 10) catch null;
            }
            if (cp) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch 0;
                try out.appendSlice(buf[0..n]);
                i = e + 1;
                continue;
            }
        };
        try out.append(s[i]);
        i += 1;
    }
    return out.items;
}

fn parseXml(a: std.mem.Allocator, src: []const u8) Error!Doc {
    var d = Doc{ .a = a };
    // корень-заглушка: 0
    try d.nodes.append(a, .{ .name = "", .attrs = &.{}, .parent = 0 });
    var cur: u32 = 0;
    var depth: usize = 0;
    var in_style = false;
    var i: usize = 0;
    while (i < src.len) {
        const lt = std.mem.indexOfScalarPos(u8, src, i, '<') orelse break;
        if (in_style and lt > i) try d.css.appendSlice(a, src[i..lt]);
        i = lt;
        const rest = src[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = if (std.mem.indexOfPos(u8, src, i + 4, "-->")) |e| e + 3 else src.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const e = std.mem.indexOfPos(u8, src, i + 9, "]]>") orelse src.len;
            if (in_style) try d.css.appendSlice(a, src[i + 9 .. e]);
            i = @min(src.len, e + 3);
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!")) {
            // DOCTYPE с внутренним подмножеством: до «]>»; сущности не раскрываются
            const br = std.mem.indexOfScalarPos(u8, src, i, '[');
            const gt = std.mem.indexOfScalarPos(u8, src, i, '>') orelse src.len;
            if (br != null and br.? < gt) {
                i = if (std.mem.indexOfPos(u8, src, br.?, "]>")) |e| e + 2 else src.len;
            } else i = @min(src.len, gt + 1);
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            i = if (std.mem.indexOfPos(u8, src, i, "?>")) |e| e + 2 else src.len;
            continue;
        }
        // тег: до «>» вне кавычек
        var j = i + 1;
        var q: u8 = 0;
        while (j < src.len) : (j += 1) {
            const c = src[j];
            if (q != 0) {
                if (c == q) q = 0;
            } else if (c == '"' or c == '\'') q = c else if (c == '>') break;
        }
        if (j >= src.len) break;
        const tag = src[i + 1 .. j];
        i = j + 1;
        if (tag.len == 0) continue;
        if (tag[0] == '/') {
            const name = localName(std.mem.trim(u8, tag[1..], " \t\r\n"));
            // закрыть до совпадающего (терпим незакрытые)
            var n = cur;
            while (n != 0 and !std.mem.eql(u8, d.nodes.items[n].name, name)) n = d.nodes.items[n].parent;
            if (n != 0) {
                if (std.mem.eql(u8, name, "style")) in_style = false;
                cur = d.nodes.items[n].parent;
                depth -|= 1;
            }
            continue;
        }
        const self_close = tag[tag.len - 1] == '/';
        const body = if (self_close) tag[0 .. tag.len - 1] else tag;
        var k: usize = 0;
        while (k < body.len and !std.ascii.isWhitespace(body[k])) k += 1;
        const name = localName(body[0..k]);
        var attrs = std.ArrayList(Attr).init(a);
        while (k < body.len) {
            while (k < body.len and std.ascii.isWhitespace(body[k])) k += 1;
            const ns = k;
            while (k < body.len and body[k] != '=' and !std.ascii.isWhitespace(body[k])) k += 1;
            const an = body[ns..k];
            while (k < body.len and std.ascii.isWhitespace(body[k])) k += 1;
            if (k >= body.len or body[k] != '=') continue;
            k += 1;
            while (k < body.len and std.ascii.isWhitespace(body[k])) k += 1;
            if (k >= body.len) break;
            const qc = body[k];
            if (qc != '"' and qc != '\'') continue;
            const ve = std.mem.indexOfScalarPos(u8, body, k + 1, qc) orelse body.len;
            const val = try decodeEntities(a, body[k + 1 .. ve]);
            k = @min(body.len, ve + 1);
            // xlink:href и href — одно; прочие префиксы срезаются
            const nm = if (std.mem.eql(u8, an, "xlink:href")) "href" else if (std.mem.startsWith(u8, an, "xmlns")) an else localName(an);
            try attrs.append(.{ .name = nm, .value = val });
        }
        if (d.nodes.items.len >= max_nodes) return error.TooBig;
        const id: u32 = @intCast(d.nodes.items.len);
        try d.nodes.append(a, .{ .name = name, .attrs = attrs.items, .parent = cur });
        try d.nodes.items[cur].kids.append(a, id);
        if (d.attr(id, "id")) |v| try d.ids.put(a, v, id);
        if (!self_close) {
            if (depth >= max_depth) return error.Damaged;
            depth += 1;
            cur = id;
            if (std.mem.eql(u8, name, "style")) in_style = true;
        }
    }
    return d;
}

pub fn looksLike(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 4096)];
    var s = head;
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s = s[3..];
    s = std.mem.trimLeft(u8, s, " \t\r\n");
    if (!(std.mem.startsWith(u8, s, "<?xml") or std.mem.startsWith(u8, s, "<svg") or std.mem.startsWith(u8, s, "<!--") or std.mem.startsWith(u8, s, "<!DOCTYPE"))) return false;
    return std.mem.indexOf(u8, head, "<svg") != null;
}

// ───────────── CSS ─────────────

const Rule = struct { tag: []const u8 = "", class: []const u8 = "", id: []const u8 = "", decls: []const u8 };

fn parseCss(a: std.mem.Allocator, css: []const u8) ![]Rule {
    var rules = std.ArrayList(Rule).init(a);
    var i: usize = 0;
    while (i < css.len) {
        const ob = std.mem.indexOfScalarPos(u8, css, i, '{') orelse break;
        const cb = std.mem.indexOfScalarPos(u8, css, ob, '}') orelse break;
        const sels = css[i..ob];
        const decls = css[ob + 1 .. cb];
        i = cb + 1;
        // комментарии внутри селекторов — редкость; @-правила пропускаются
        if (std.mem.indexOfScalar(u8, sels, '@') != null) continue;
        var it = std.mem.splitScalar(u8, sels, ',');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            if (s.len == 0 or std.mem.indexOfAny(u8, s, " >+~:[") != null) continue;
            var r = Rule{ .decls = decls };
            if (s[0] == '.') r.class = s[1..] else if (s[0] == '#') r.id = s[1..] else if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
                r.tag = s[0..dot];
                r.class = s[dot + 1 ..];
            } else r.tag = s;
            try rules.append(r);
        }
    }
    return rules.items;
}

fn declValue(decls: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, decls, ';');
    var found: ?[]const u8 = null;
    while (it.next()) |d| {
        const c = std.mem.indexOfScalar(u8, d, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, d[0..c], " \t\r\n"), name)) {
            var v = std.mem.trim(u8, d[c + 1 ..], " \t\r\n");
            if (std.mem.endsWith(u8, v, "!important")) v = std.mem.trim(u8, v[0 .. v.len - 10], " ");
            found = v;
        }
    }
    return found;
}

fn hasClass(list: []const u8, cls: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |c| if (std.mem.eql(u8, c, cls)) return true;
    return false;
}

// ───────────── цвета ─────────────

const named =
    "aliceblue:f0f8ff antiquewhite:faebd7 aqua:00ffff aquamarine:7fffd4 azure:f0ffff beige:f5f5dc bisque:ffe4c4 black:000000 " ++
    "blanchedalmond:ffebcd blue:0000ff blueviolet:8a2be2 brown:a52a2a burlywood:deb887 cadetblue:5f9ea0 chartreuse:7fff00 " ++
    "chocolate:d2691e coral:ff7f50 cornflowerblue:6495ed cornsilk:fff8dc crimson:dc143c cyan:00ffff darkblue:00008b " ++
    "darkcyan:008b8b darkgoldenrod:b8860b darkgray:a9a9a9 darkgreen:006400 darkgrey:a9a9a9 darkkhaki:bdb76b darkmagenta:8b008b " ++
    "darkolivegreen:556b2f darkorange:ff8c00 darkorchid:9932cc darkred:8b0000 darksalmon:e9967a darkseagreen:8fbc8f " ++
    "darkslateblue:483d8b darkslategray:2f4f4f darkslategrey:2f4f4f darkturquoise:00ced1 darkviolet:9400d3 deeppink:ff1493 " ++
    "deepskyblue:00bfff dimgray:696969 dimgrey:696969 dodgerblue:1e90ff firebrick:b22222 floralwhite:fffaf0 forestgreen:228b22 " ++
    "fuchsia:ff00ff gainsboro:dcdcdc ghostwhite:f8f8ff gold:ffd700 goldenrod:daa520 gray:808080 grey:808080 green:008000 " ++
    "greenyellow:adff2f honeydew:f0fff0 hotpink:ff69b4 indianred:cd5c5c indigo:4b0082 ivory:fffff0 khaki:f0e68c lavender:e6e6fa " ++
    "lavenderblush:fff0f5 lawngreen:7cfc00 lemonchiffon:fffacd lightblue:add8e6 lightcoral:f08080 lightcyan:e0ffff " ++
    "lightgoldenrodyellow:fafad2 lightgray:d3d3d3 lightgreen:90ee90 lightgrey:d3d3d3 lightpink:ffb6c1 lightsalmon:ffa07a " ++
    "lightseagreen:20b2aa lightskyblue:87cefa lightslategray:778899 lightslategrey:778899 lightsteelblue:b0c4de lightyellow:ffffe0 " ++
    "lime:00ff00 limegreen:32cd32 linen:faf0e6 magenta:ff00ff maroon:800000 mediumaquamarine:66cdaa mediumblue:0000cd " ++
    "mediumorchid:ba55d3 mediumpurple:9370db mediumseagreen:3cb371 mediumslateblue:7b68ee mediumspringgreen:00fa9a " ++
    "mediumturquoise:48d1cc mediumvioletred:c71585 midnightblue:191970 mintcream:f5fffa mistyrose:ffe4e1 moccasin:ffe4b5 " ++
    "navajowhite:ffdead navy:000080 oldlace:fdf5e6 olive:808000 olivedrab:6b8e23 orange:ffa500 orangered:ff4500 orchid:da70d6 " ++
    "palegoldenrod:eee8aa palegreen:98fb98 paleturquoise:afeeee palevioletred:db7093 papayawhip:ffefd5 peachpuff:ffdab9 " ++
    "peru:cd853f pink:ffc0cb plum:dda0dd powderblue:b0e0e6 purple:800080 rebeccapurple:663399 red:ff0000 rosybrown:bc8f8f " ++
    "royalblue:4169e1 saddlebrown:8b4513 salmon:fa8072 sandybrown:f4a460 seagreen:2e8b57 seashell:fff5ee sienna:a0522d " ++
    "silver:c0c0c0 skyblue:87ceeb slateblue:6a5acd slategray:708090 slategrey:708090 snow:fffafa springgreen:00ff7f " ++
    "steelblue:4682b4 tan:d2b48c teal:008080 thistle:d8bfd8 tomato:ff6347 turquoise:40e0d0 violet:ee82ee wheat:f5deb3 " ++
    "white:ffffff whitesmoke:f5f5f5 yellow:ffff00 yellowgreen:9acd32";

const Rgba = [4]f32; // 0..1, не умножено на альфу

fn hexColor(h: []const u8) ?Rgba {
    var v: [4]u8 = .{ 0, 0, 0, 255 };
    switch (h.len) {
        3, 4 => for (0..h.len) |k| {
            const d = std.fmt.charToDigit(h[k], 16) catch return null;
            v[k] = d * 17;
        },
        6, 8 => for (0..h.len / 2) |k| {
            v[k] = std.fmt.parseInt(u8, h[k * 2 ..][0..2], 16) catch return null;
        },
        else => return null,
    }
    return .{ @as(f32, @floatFromInt(v[0])) / 255, @as(f32, @floatFromInt(v[1])) / 255, @as(f32, @floatFromInt(v[2])) / 255, @as(f32, @floatFromInt(v[3])) / 255 };
}

fn parseColor(s0: []const u8, current: Rgba) ?Rgba {
    const s = std.mem.trim(u8, s0, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') return hexColor(s[1..]);
    if (std.ascii.eqlIgnoreCase(s, "currentColor")) return current;
    if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ 0, 0, 0, 0 };
    if (std.ascii.startsWithIgnoreCase(s, "rgb")) {
        const o = std.mem.indexOfScalar(u8, s, '(') orelse return null;
        const c = std.mem.indexOfScalar(u8, s, ')') orelse return null;
        var it = std.mem.tokenizeAny(u8, s[o + 1 .. c], ", \t/");
        var v: Rgba = .{ 0, 0, 0, 1 };
        var k: usize = 0;
        while (it.next()) |t| : (k += 1) {
            if (k >= 4) break;
            const pct = std.mem.endsWith(u8, t, "%");
            const num = std.fmt.parseFloat(f32, if (pct) t[0 .. t.len - 1] else t) catch return null;
            v[k] = if (k == 3) (if (pct) num / 100 else num) else (if (pct) num / 100 else num / 255);
            v[k] = std.math.clamp(v[k], 0, 1);
        }
        return v;
    }
    if (std.ascii.startsWithIgnoreCase(s, "hsl")) {
        const o = std.mem.indexOfScalar(u8, s, '(') orelse return null;
        const c = std.mem.indexOfScalar(u8, s, ')') orelse return null;
        var it = std.mem.tokenizeAny(u8, s[o + 1 .. c], ", \t/");
        var v: [4]f32 = .{ 0, 0, 0, 1 };
        var k: usize = 0;
        while (it.next()) |t0| : (k += 1) {
            if (k >= 4) break;
            var t = t0;
            if (std.mem.endsWith(u8, t, "deg")) t = t[0 .. t.len - 3];
            const pct = std.mem.endsWith(u8, t, "%");
            const num = std.fmt.parseFloat(f32, if (pct) t[0 .. t.len - 1] else t) catch return null;
            v[k] = if (k == 0) num else if (k == 3 and !pct) num else num / 100;
        }
        const h = @mod(v[0], 360) / 60;
        const sat = std.math.clamp(v[1], 0, 1);
        const l = std.math.clamp(v[2], 0, 1);
        const ch = (1 - @abs(2 * l - 1)) * sat;
        const x = ch * (1 - @abs(@mod(h, 2) - 1));
        const m = l - ch / 2;
        const rgb: [3]f32 = if (h < 1) .{ ch, x, 0 } else if (h < 2) .{ x, ch, 0 } else if (h < 3) .{ 0, ch, x } else if (h < 4) .{ 0, x, ch } else if (h < 5) .{ x, 0, ch } else .{ ch, 0, x };
        return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m, std.math.clamp(v[3], 0, 1) };
    }
    var it = std.mem.tokenizeScalar(u8, named, ' ');
    while (it.next()) |e| {
        const c = std.mem.indexOfScalar(u8, e, ':').?;
        if (std.ascii.eqlIgnoreCase(e[0..c], s)) return hexColor(e[c + 1 ..]);
    }
    return null;
}

// ───────────── геометрия ─────────────

const Pt = struct { x: f32, y: f32 };

const Mat = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    fn mul(m: Mat, n: Mat) Mat { // m · n: сначала n, потом m
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }
    fn apply(m: Mat, p: Pt) Pt {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }
    fn inv(m: Mat) ?Mat {
        const det = m.a * m.d - m.b * m.c;
        if (@abs(det) < 1e-12) return null;
        const r = 1 / det;
        return .{ .a = m.d * r, .b = -m.b * r, .c = -m.c * r, .d = m.a * r, .e = (m.c * m.f - m.d * m.e) * r, .f = (m.b * m.e - m.a * m.f) * r };
    }
    fn scale(m: Mat) f32 {
        return @sqrt(@abs(m.a * m.d - m.b * m.c));
    }
};

fn translate(x: f32, y: f32) Mat {
    return .{ .e = x, .f = y };
}

/// Числа подряд: «10-5», «.5.5», «1e3» — по правилам SVG.
const Nums = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(n: *Nums) void {
        while (n.i < n.s.len and (std.ascii.isWhitespace(n.s[n.i]) or n.s[n.i] == ',')) n.i += 1;
    }

    fn more(n: *Nums) bool {
        n.skipSep();
        if (n.i >= n.s.len) return false;
        const c = n.s[n.i];
        return std.ascii.isDigit(c) or c == '-' or c == '+' or c == '.';
    }

    fn num(n: *Nums) ?f32 {
        n.skipSep();
        const st = n.i;
        var i = n.i;
        if (i < n.s.len and (n.s[i] == '-' or n.s[i] == '+')) i += 1;
        var dot = false;
        var digits = false;
        while (i < n.s.len) : (i += 1) {
            const c = n.s[i];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (!digits) return null;
        if (i < n.s.len and (n.s[i] == 'e' or n.s[i] == 'E')) {
            var j = i + 1;
            if (j < n.s.len and (n.s[j] == '-' or n.s[j] == '+')) j += 1;
            if (j < n.s.len and std.ascii.isDigit(n.s[j])) {
                while (j < n.s.len and std.ascii.isDigit(n.s[j])) j += 1;
                i = j;
            }
        }
        n.i = i;
        const v = std.fmt.parseFloat(f32, n.s[st..i]) catch return null;
        return if (std.math.isFinite(v)) v else null;
    }

    /// Флаг дуги: одна цифра 0 или 1, разделитель не обязателен.
    fn flag(n: *Nums) ?bool {
        n.skipSep();
        if (n.i >= n.s.len) return null;
        const c = n.s[n.i];
        if (c != '0' and c != '1') return null;
        n.i += 1;
        return c == '1';
    }
};

fn parseTransform(s: []const u8) Mat {
    var m = Mat{};
    var i: usize = 0;
    while (i < s.len) {
        const o = std.mem.indexOfScalarPos(u8, s, i, '(') orelse break;
        const c = std.mem.indexOfScalarPos(u8, s, o, ')') orelse break;
        const name = std.mem.trim(u8, s[i..o], " \t\r\n,");
        var ns = Nums{ .s = s[o + 1 .. c] };
        var v: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        var n: usize = 0;
        while (n < 6) : (n += 1) v[n] = ns.num() orelse break;
        i = c + 1;
        const t: Mat = if (std.mem.eql(u8, name, "matrix") and n == 6)
            .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] }
        else if (std.mem.eql(u8, name, "translate"))
            translate(v[0], if (n > 1) v[1] else 0)
        else if (std.mem.eql(u8, name, "scale"))
            .{ .a = v[0], .d = if (n > 1) v[1] else v[0] }
        else if (std.mem.eql(u8, name, "rotate")) blk: {
            const r = v[0] * std.math.pi / 180;
            const rot = Mat{ .a = @cos(r), .b = @sin(r), .c = -@sin(r), .d = @cos(r) };
            break :blk if (n >= 3) translate(v[1], v[2]).mul(rot).mul(translate(-v[1], -v[2])) else rot;
        } else if (std.mem.eql(u8, name, "skewX"))
            .{ .c = @tan(v[0] * std.math.pi / 180) }
        else if (std.mem.eql(u8, name, "skewY"))
            .{ .b = @tan(v[0] * std.math.pi / 180) }
        else
            .{};
        m = m.mul(t);
    }
    return m;
}

/// Подпути в координатах устройства.
const Path = struct {
    a: std.mem.Allocator,
    subs: std.ArrayListUnmanaged(Sub) = .{},
    m: Mat,
    tol: f32,
    points: *usize,

    const Sub = struct { pts: std.ArrayListUnmanaged(Pt) = .{}, closed: bool = false };

    fn moveTo(p: *Path, q: Pt) !void {
        try p.subs.append(p.a, .{});
        try p.lineTo(q);
    }

    fn lineTo(p: *Path, q: Pt) !void {
        if (p.subs.items.len == 0) try p.subs.append(p.a, .{});
        p.points.* += 1;
        if (p.points.* > max_points) return error.TooBig;
        try p.subs.items[p.subs.items.len - 1].pts.append(p.a, p.m.apply(q));
    }

    fn close(p: *Path) void {
        if (p.subs.items.len > 0) p.subs.items[p.subs.items.len - 1].closed = true;
    }

    /// Кубическая Безье в пространстве пользователя: делится, пока не станет плоской на экране.
    fn cubic(p: *Path, p0: Pt, p1: Pt, p2: Pt, p3: Pt) !void {
        const d0 = p.m.apply(p0);
        const d1 = p.m.apply(p1);
        const d2 = p.m.apply(p2);
        const d3 = p.m.apply(p3);
        const dd = @abs(d1.x - d0.x) + @abs(d1.y - d0.y) + @abs(d2.x - d1.x) + @abs(d2.y - d1.y) + @abs(d3.x - d2.x) + @abs(d3.y - d2.y);
        const n: usize = toInt(@ceil(@sqrt(dd / p.tol) * 0.75), 1, 512);
        for (1..n + 1) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            const q = Pt{
                .x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                .y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
            };
            try p.lineTo(q);
        }
    }

    /// Дуга эллипса (SVG, приложение F.6) — кубическими кусками не больше 90°.
    fn arc(p: *Path, from: Pt, rx0: f32, ry0: f32, phi_deg: f32, large: bool, sweep: bool, to: Pt) !void {
        var rx = @abs(rx0);
        var ry = @abs(ry0);
        if (rx == 0 or ry == 0) return p.lineTo(to);
        if (from.x == to.x and from.y == to.y) return;
        const phi = phi_deg * std.math.pi / 180;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (from.x - to.x) / 2;
        const dy = (from.y - to.y) / 2;
        const x1 = cp * dx + sp * dy;
        const y1 = -sp * dx + cp * dy;
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1) {
            rx *= @sqrt(lam);
            ry *= @sqrt(lam);
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = if (den == 0) 0 else @sqrt(@max(0, num / den));
        if (large == sweep) co = -co;
        const cx1 = co * rx * y1 / ry;
        const cy1 = -co * ry * x1 / rx;
        const cx = cp * cx1 - sp * cy1 + (from.x + to.x) / 2;
        const cy = sp * cx1 + cp * cy1 + (from.y + to.y) / 2;
        const ang = struct {
            fn f(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
                const s = ux * vy - uy * vx;
                return std.math.atan2(s, ux * vx + uy * vy);
            }
        }.f;
        const t1 = ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry);
        var dt = ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        if (!std.math.isFinite(dt) or !std.math.isFinite(t1)) return p.lineTo(to);
        const segs: usize = toInt(@ceil(@abs(dt) / (std.math.pi / 2.0) - 1e-4), 1, 4);
        const n = @max(segs, 1);
        const step = dt / @as(f32, @floatFromInt(n));
        const k = 4.0 / 3.0 * @tan(step / 4);
        var a0 = t1;
        for (0..n) |_| {
            const a1 = a0 + step;
            const e0 = Pt{ .x = @cos(a0), .y = @sin(a0) };
            const e1 = Pt{ .x = @cos(a1), .y = @sin(a1) };
            const pts = [4]Pt{ e0, .{ .x = e0.x - k * e0.y, .y = e0.y + k * e0.x }, .{ .x = e1.x + k * e1.y, .y = e1.y - k * e1.x }, e1 };
            var q: [4]Pt = undefined;
            for (pts, 0..) |e, i| {
                const xx = e.x * rx;
                const yy = e.y * ry;
                q[i] = .{ .x = cp * xx - sp * yy + cx, .y = sp * xx + cp * yy + cy };
            }
            try p.cubic(q[0], q[1], q[2], q[3]);
            a0 = a1;
        }
    }
};

fn buildPathData(p: *Path, d: []const u8) !void {
    var n = Nums{ .s = d };
    var cur = Pt{ .x = 0, .y = 0 };
    var start = cur;
    var last_c: ?Pt = null; // вторая опорная точка прошлой кубической
    var last_q: ?Pt = null;
    var cmd: u8 = 0;
    while (true) {
        n.skipSep();
        if (n.i >= n.s.len) break;
        const c = n.s[n.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            n.i += 1;
        } else if (cmd == 0) return;
        const rel = std.ascii.isLower(cmd);
        const base = if (rel) cur else Pt{ .x = 0, .y = 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = n.num() orelse return;
                const y = n.num() orelse return;
                cur = .{ .x = base.x + x, .y = base.y + y };
                start = cur;
                try p.moveTo(cur);
                cmd = if (rel) 'l' else 'L'; // дальше пары — линии
                last_c = null;
                last_q = null;
            },
            'L' => {
                const x = n.num() orelse return;
                const y = n.num() orelse return;
                cur = .{ .x = base.x + x, .y = base.y + y };
                try p.lineTo(cur);
                last_c = null;
                last_q = null;
            },
            'H' => {
                const x = n.num() orelse return;
                cur.x = (if (rel) cur.x else 0) + x;
                try p.lineTo(cur);
                last_c = null;
                last_q = null;
            },
            'V' => {
                const y = n.num() orelse return;
                cur.y = (if (rel) cur.y else 0) + y;
                try p.lineTo(cur);
                last_c = null;
                last_q = null;
            },
            'C', 'S' => {
                var c1: Pt = undefined;
                if (std.ascii.toUpper(cmd) == 'C') {
                    const x1 = n.num() orelse return;
                    const y1 = n.num() orelse return;
                    c1 = .{ .x = base.x + x1, .y = base.y + y1 };
                } else c1 = if (last_c) |l| Pt{ .x = 2 * cur.x - l.x, .y = 2 * cur.y - l.y } else cur;
                const x2 = n.num() orelse return;
                const y2 = n.num() orelse return;
                const x = n.num() orelse return;
                const y = n.num() orelse return;
                const c2 = Pt{ .x = base.x + x2, .y = base.y + y2 };
                const e = Pt{ .x = base.x + x, .y = base.y + y };
                try p.cubic(cur, c1, c2, e);
                last_c = c2;
                last_q = null;
                cur = e;
            },
            'Q', 'T' => {
                var q: Pt = undefined;
                if (std.ascii.toUpper(cmd) == 'Q') {
                    const x1 = n.num() orelse return;
                    const y1 = n.num() orelse return;
                    q = .{ .x = base.x + x1, .y = base.y + y1 };
                } else q = if (last_q) |l| Pt{ .x = 2 * cur.x - l.x, .y = 2 * cur.y - l.y } else cur;
                const x = n.num() orelse return;
                const y = n.num() orelse return;
                const e = Pt{ .x = base.x + x, .y = base.y + y };
                try p.cubic(cur, .{ .x = cur.x + 2.0 / 3.0 * (q.x - cur.x), .y = cur.y + 2.0 / 3.0 * (q.y - cur.y) }, .{ .x = e.x + 2.0 / 3.0 * (q.x - e.x), .y = e.y + 2.0 / 3.0 * (q.y - e.y) }, e);
                last_q = q;
                last_c = null;
                cur = e;
            },
            'A' => {
                const rx = n.num() orelse return;
                const ry = n.num() orelse return;
                const rot = n.num() orelse return;
                const large = n.flag() orelse return;
                const sweep = n.flag() orelse return;
                const x = n.num() orelse return;
                const y = n.num() orelse return;
                const e = Pt{ .x = base.x + x, .y = base.y + y };
                try p.arc(cur, rx, ry, rot, large, sweep, e);
                cur = e;
                last_c = null;
                last_q = null;
            },
            'Z' => {
                p.close();
                cur = start;
                last_c = null;
                last_q = null;
                // после Z новая команда обязательна; число — ошибка, конец разбора
                n.skipSep();
                if (n.more()) {
                    // по стандарту — ошибка; терпимо продолжаем как с M
                    try p.moveTo(cur);
                    cmd = if (rel) 'l' else 'L';
                }
                continue;
            },
            else => return,
        }
    }
}

fn ellipsePath(p: *Path, cx: f32, cy: f32, rx: f32, ry: f32) !void {
    if (rx <= 0 or ry <= 0) return;
    const k: f32 = 0.5522847498;
    try p.moveTo(.{ .x = cx + rx, .y = cy });
    try p.cubic(.{ .x = cx + rx, .y = cy }, .{ .x = cx + rx, .y = cy + k * ry }, .{ .x = cx + k * rx, .y = cy + ry }, .{ .x = cx, .y = cy + ry });
    try p.cubic(.{ .x = cx, .y = cy + ry }, .{ .x = cx - k * rx, .y = cy + ry }, .{ .x = cx - rx, .y = cy + k * ry }, .{ .x = cx - rx, .y = cy });
    try p.cubic(.{ .x = cx - rx, .y = cy }, .{ .x = cx - rx, .y = cy - k * ry }, .{ .x = cx - k * rx, .y = cy - ry }, .{ .x = cx, .y = cy - ry });
    try p.cubic(.{ .x = cx, .y = cy - ry }, .{ .x = cx + k * rx, .y = cy - ry }, .{ .x = cx + rx, .y = cy - k * ry }, .{ .x = cx + rx, .y = cy });
    p.close();
}

// ───────────── растеризация ─────────────

const sub_rows = 5;

const Canvas = struct {
    w: u32,
    h: u32,
    /// RGBA, умножено на альфу
    px: []f32,
    cover: []f32,
};

const Paint = union(enum) {
    none,
    color: Rgba,
    grad: Grad,
};

const Stop = struct { off: f32, c: Rgba };

const Grad = struct {
    radial: bool,
    /// устройство → пространство градиента
    inv: Mat,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    r: f32,
    fx: f32,
    fy: f32,
    spread: u8, // 0 pad, 1 reflect, 2 repeat
    stops: []const Stop,

    fn at(g: *const Grad, x: f32, y: f32) Rgba {
        const p = g.inv.apply(.{ .x = x, .y = y });
        var t: f32 = 0;
        if (!g.radial) {
            const dx = g.x2 - g.x1;
            const dy = g.y2 - g.y1;
            const l2 = dx * dx + dy * dy;
            t = if (l2 > 0) ((p.x - g.x1) * dx + (p.y - g.y1) * dy) / l2 else 0;
        } else {
            const dx = g.x1 - g.fx; // центр − фокус
            const dy = g.y1 - g.fy;
            const qx = p.x - g.fx;
            const qy = p.y - g.fy;
            const a = dx * dx + dy * dy - g.r * g.r;
            const qd = qx * dx + qy * dy;
            const qq = qx * qx + qy * qy;
            if (@abs(a) < 1e-6) {
                t = if (qd != 0) qq / (2 * qd) else 0;
            } else {
                const disc = @max(0, qd * qd - a * qq);
                t = (qd - @sqrt(disc)) / a;
            }
        }
        switch (g.spread) {
            1 => {
                t = @mod(t, 2);
                if (t > 1) t = 2 - t;
            },
            2 => t = t - @floor(t),
            else => t = std.math.clamp(t, 0, 1),
        }
        const s = g.stops;
        if (t <= s[0].off) return s[0].c;
        for (1..s.len) |k| if (t <= s[k].off) {
            const span = s[k].off - s[k - 1].off;
            const f = if (span > 0) (t - s[k - 1].off) / span else 1;
            var c: Rgba = undefined;
            for (0..4) |i| c[i] = s[k - 1].c[i] + (s[k].c[i] - s[k - 1].c[i]) * f;
            return c;
        };
        return s[s.len - 1].c;
    }
};

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i8 };

/// Заливка многоугольников (подпути замыкаются) с правилом и краской.
fn fill(cv: *Canvas, a: std.mem.Allocator, polys: []const []const Pt, evenodd: bool, paint: *const Paint, alpha: f32) !void {
    if (paint.* == .none or alpha <= 0) return;
    var edges = std.ArrayList(Edge).init(a);
    defer edges.deinit();
    var ymin: f32 = std.math.inf(f32);
    var ymax: f32 = -std.math.inf(f32);
    for (polys) |pts| {
        if (pts.len < 2) continue;
        for (0..pts.len) |k| {
            const p0 = pts[k];
            const p1 = pts[(k + 1) % pts.len];
            if (p0.y == p1.y or !std.math.isFinite(p0.x + p0.y + p1.x + p1.y)) continue;
            const e = if (p0.y < p1.y) Edge{ .x0 = p0.x, .y0 = p0.y, .x1 = p1.x, .y1 = p1.y, .dir = 1 } else Edge{ .x0 = p1.x, .y0 = p1.y, .x1 = p0.x, .y1 = p0.y, .dir = -1 };
            ymin = @min(ymin, e.y0);
            ymax = @max(ymax, e.y1);
            try edges.append(e);
        }
    }
    if (edges.items.len == 0) return;
    std.mem.sort(Edge, edges.items, {}, struct {
        fn lt(_: void, x: Edge, y: Edge) bool {
            return x.y0 < y.y0;
        }
    }.lt);
    const W: f32 = @floatFromInt(cv.w);
    const y_from: u32 = @intCast(toInt(@floor(ymin), 0, cv.h));
    const y_to: u32 = @intCast(toInt(@ceil(ymax), 0, cv.h));
    var active = std.ArrayList(u32).init(a);
    defer active.deinit();
    const Cross = struct { x: f32, dir: i8 };
    var xs = std.ArrayList(Cross).init(a);
    defer xs.deinit();
    var next_edge: usize = 0;
    var y = y_from;
    while (y < y_to) : (y += 1) {
        var lo: usize = cv.w;
        var hi: usize = 0;
        for (0..sub_rows) |s| {
            const sy: f32 = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, sub_rows);
            while (next_edge < edges.items.len and edges.items[next_edge].y0 <= sy) : (next_edge += 1) try active.append(@intCast(next_edge));
            xs.clearRetainingCapacity();
            var k: usize = 0;
            while (k < active.items.len) {
                const e = edges.items[active.items[k]];
                if (e.y1 <= sy) {
                    _ = active.swapRemove(k);
                    continue;
                }
                if (e.y0 <= sy) try xs.append(.{ .x = e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0), .dir = e.dir });
                k += 1;
            }
            std.mem.sort(Cross, xs.items, {}, struct {
                fn lt(_: void, p: Cross, q: Cross) bool {
                    return p.x < q.x;
                }
            }.lt);
            var wind: i32 = 0;
            for (0..xs.items.len) |i| {
                const was_in = if (evenodd) @mod(wind, 2) != 0 else wind != 0;
                wind += xs.items[i].dir;
                _ = was_in;
                const inside = if (evenodd) @mod(wind, 2) != 0 else wind != 0;
                if (!inside or i + 1 >= xs.items.len) continue;
                const xa = std.math.clamp(xs.items[i].x, 0, W);
                const xb = std.math.clamp(xs.items[i + 1].x, 0, W);
                if (xb <= xa) continue;
                const ia: usize = toInt(@floor(xa), 0, cv.w);
                const ib: usize = toInt(@floor(xb), 0, cv.w);
                const sw: f32 = 1.0 / @as(f32, sub_rows);
                if (ia == ib) {
                    if (ia < cv.w) cv.cover[ia] += (xb - xa) * sw;
                } else {
                    cv.cover[ia] += (@as(f32, @floatFromInt(ia + 1)) - xa) * sw;
                    for (ia + 1..ib) |x| cv.cover[x] += sw;
                    if (ib < cv.w) cv.cover[ib] += (xb - @as(f32, @floatFromInt(ib))) * sw;
                }
                lo = @min(lo, ia);
                hi = @max(hi, @min(ib + 1, cv.w));
            }
        }
        // наложение строки
        var x = lo;
        while (x < hi) : (x += 1) {
            const cvr = @min(cv.cover[x], 1);
            cv.cover[x] = 0;
            if (cvr <= 0) continue;
            const c: Rgba = switch (paint.*) {
                .color => |col| col,
                .grad => |*g| g.at(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5),
                .none => unreachable,
            };
            const sa = c[3] * alpha * cvr;
            const d = cv.px[(@as(usize, y) * cv.w + x) * 4 ..][0..4];
            for (0..3) |i| d[i] = c[i] * sa + d[i] * (1 - sa);
            d[3] = sa + d[3] * (1 - sa);
        }
    }
}

// ───────────── обводка ─────────────

const Stroke = struct { w: f32, cap: u8 = 0, join: u8 = 0, miter: f32 = 4 }; // cap: 0 butt 1 round 2 square; join: 0 miter 1 round 2 bevel

fn orient(a: std.mem.Allocator, pts: []const Pt, out: *std.ArrayList([]const Pt)) !void {
    var area: f32 = 0;
    for (0..pts.len) |k| {
        const p = pts[k];
        const q = pts[(k + 1) % pts.len];
        area += p.x * q.y - q.x * p.y;
    }
    const v = try a.dupe(Pt, pts);
    if (area < 0) std.mem.reverse(Pt, v);
    try out.append(v);
}

fn circlePoly(a: std.mem.Allocator, c: Pt, r: f32, out: *std.ArrayList([]const Pt)) !void {
    const n: usize = toInt(@ceil(2 * std.math.pi * r / 1.5), 8, 128);
    const v = try a.alloc(Pt, n);
    for (v, 0..) |*p, k| {
        const t = @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(n));
        p.* = .{ .x = c.x + r * @cos(t), .y = c.y + r * @sin(t) };
    }
    try orient(a, v, out);
}

/// Обводка ломаной (в координатах устройства) → набор многоугольников одной ориентации.
fn strokePolys(a: std.mem.Allocator, raw: []const Pt, closed: bool, st: Stroke, out: *std.ArrayList([]const Pt)) !void {
    // без повторов
    var pts = std.ArrayList(Pt).init(a);
    for (raw) |p| {
        if (pts.items.len > 0) {
            const l = pts.items[pts.items.len - 1];
            if (@abs(l.x - p.x) < 1e-4 and @abs(l.y - p.y) < 1e-4) continue;
        }
        try pts.append(p);
    }
    if (closed and pts.items.len > 1) {
        const f = pts.items[0];
        const l = pts.items[pts.items.len - 1];
        if (@abs(l.x - f.x) < 1e-4 and @abs(l.y - f.y) < 1e-4) pts.items.len -= 1;
    }
    const hw = st.w / 2;
    const v = pts.items;
    if (v.len == 0) return;
    if (v.len == 1) {
        if (st.cap == 1) try circlePoly(a, v[0], hw, out) else if (st.cap == 2) try orient(a, &.{ .{ .x = v[0].x - hw, .y = v[0].y - hw }, .{ .x = v[0].x + hw, .y = v[0].y - hw }, .{ .x = v[0].x + hw, .y = v[0].y + hw }, .{ .x = v[0].x - hw, .y = v[0].y + hw } }, out);
        return;
    }
    const n_seg = if (closed) v.len else v.len - 1;
    for (0..n_seg) |k| {
        var p0 = v[k];
        var p1 = v[(k + 1) % v.len];
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const len = @sqrt(dx * dx + dy * dy);
        const ux = dx / len;
        const uy = dy / len;
        if (!closed and st.cap == 2) {
            if (k == 0) p0 = .{ .x = p0.x - ux * hw, .y = p0.y - uy * hw };
            if (k == n_seg - 1) p1 = .{ .x = p1.x + ux * hw, .y = p1.y + uy * hw };
        }
        const nx = -uy * hw;
        const ny = ux * hw;
        try orient(a, &.{ .{ .x = p0.x + nx, .y = p0.y + ny }, .{ .x = p1.x + nx, .y = p1.y + ny }, .{ .x = p1.x - nx, .y = p1.y - ny }, .{ .x = p0.x - nx, .y = p0.y - ny } }, out);
    }
    // соединения
    const first_join: usize = if (closed) 0 else 1;
    const last_join: usize = if (closed) v.len else v.len - 1;
    for (first_join..last_join) |k| {
        const p = v[k];
        const pa = v[(k + v.len - 1) % v.len];
        const pb = v[(k + 1) % v.len];
        if (st.join == 1) {
            try circlePoly(a, p, hw, out);
            continue;
        }
        const l0 = @sqrt((p.x - pa.x) * (p.x - pa.x) + (p.y - pa.y) * (p.y - pa.y));
        const l1 = @sqrt((pb.x - p.x) * (pb.x - p.x) + (pb.y - p.y) * (pb.y - p.y));
        const ua = Pt{ .x = (p.x - pa.x) / l0, .y = (p.y - pa.y) / l0 };
        const ub = Pt{ .x = (pb.x - p.x) / l1, .y = (pb.y - p.y) / l1 };
        const cross = ua.x * ub.y - ua.y * ub.x;
        if (@abs(cross) < 1e-6 and ua.x * ub.x + ua.y * ub.y > 0) continue; // прямая
        // внешняя сторона — против поворота
        const s: f32 = if (cross > 0) -1 else 1;
        const n0 = Pt{ .x = -ua.y * hw * s, .y = ua.x * hw * s };
        const n1 = Pt{ .x = -ub.y * hw * s, .y = ub.x * hw * s };
        const a0 = Pt{ .x = p.x + n0.x, .y = p.y + n0.y };
        const a1 = Pt{ .x = p.x + n1.x, .y = p.y + n1.y };
        if (st.join == 0) {
            const cos_t = -(ua.x * ub.x + ua.y * ub.y); // угол между отрезками
            const sin_half = @sqrt(@max(0, (1 - cos_t) / 2));
            if (sin_half > 1e-6 and 1 / sin_half <= st.miter) {
                // вершина острия — на биссектрисе
                const bx = n0.x + n1.x;
                const by = n0.y + n1.y;
                const bl = @sqrt(bx * bx + by * by);
                if (bl > 1e-6) {
                    const ml = hw / sin_half;
                    const tip = Pt{ .x = p.x + bx / bl * ml, .y = p.y + by / bl * ml };
                    try orient(a, &.{ p, a0, tip, a1 }, out);
                    continue;
                }
            }
        }
        try orient(a, &.{ p, a0, a1 }, out);
    }
    if (!closed and st.cap == 1) {
        try circlePoly(a, v[0], hw, out);
        try circlePoly(a, v[v.len - 1], hw, out);
    }
}

/// Пунктир: ломаная → куски «вкл» по массиву длин (в устройстве).
fn dashes(a: std.mem.Allocator, pts: []const Pt, closed: bool, arr: []const f32, offset: f32, out: *std.ArrayList([]Pt)) !void {
    var total: f32 = 0;
    for (arr) |d| total += d;
    if (total <= 0) return;
    var seq = std.ArrayList(Pt).init(a);
    try seq.appendSlice(pts);
    if (closed and pts.len > 0) try seq.append(pts[0]);
    var idx: usize = 0;
    var left = arr[0];
    var on = true;
    // сдвиг
    var off = @mod(offset, total);
    while (off > 0) {
        if (off >= left) {
            off -= left;
            idx = (idx + 1) % arr.len;
            left = arr[idx];
            on = !on;
        } else {
            left -= off;
            off = 0;
        }
    }
    var cur = std.ArrayList(Pt).init(a);
    if (on and seq.items.len > 0) try cur.append(seq.items[0]);
    var guard: usize = 0;
    for (1..seq.items.len) |k| {
        var p0 = seq.items[k - 1];
        const p1 = seq.items[k];
        var seg = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y));
        while (seg > 0) {
            guard += 1;
            if (guard > 2_000_000) return error.TooBig;
            if (left > seg) {
                left -= seg;
                if (on) try cur.append(p1);
                break;
            }
            const t = left / seg;
            const q = Pt{ .x = p0.x + (p1.x - p0.x) * t, .y = p0.y + (p1.y - p0.y) * t };
            if (on) {
                try cur.append(q);
                try out.append(try cur.toOwnedSlice());
            } else {
                cur.clearRetainingCapacity();
                try cur.append(q);
            }
            seg -= left;
            p0 = q;
            on = !on;
            idx = (idx + 1) % arr.len;
            left = arr[idx];
            if (left <= 0) left = 1e-3;
        }
    }
    if (on and cur.items.len > 1) try out.append(try cur.toOwnedSlice());
}

// ───────────── стиль и обход ─────────────

const Style = struct {
    fill: Paint = .{ .color = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    stroke_w: f32 = 1,
    fill_op: f32 = 1,
    stroke_op: f32 = 1,
    opacity: f32 = 1,
    evenodd: bool = false,
    cap: u8 = 0,
    join: u8 = 0,
    miter: f32 = 4,
    dash: []const f32 = &.{},
    dash_off: f32 = 0,
    color: Rgba = .{ 0, 0, 0, 1 },
    visible: bool = true,
    // ссылки на градиенты разрешаются при отрисовке фигуры (нужна её рамка)
    fill_ref: ?u32 = null,
    stroke_ref: ?u32 = null,
};

const R = struct {
    a: std.mem.Allocator,
    d: *Doc,
    rules: []Rule,
    cv: *Canvas,
    vw: f32,
    vh: f32,
    points: usize = 0,
    use_depth: usize = 0,

    /// Значение свойства у узла: style= > правила <style> > атрибут.
    fn prop(r: *R, n: u32, name: []const u8) ?[]const u8 {
        if (r.d.attr(n, "style")) |st| if (declValue(st, name)) |v| return v;
        var found: ?[]const u8 = null;
        const node = &r.d.nodes.items[n];
        const cls = r.d.attr(n, "class") orelse "";
        const id = r.d.attr(n, "id") orelse "";
        for (r.rules) |rule| {
            if (rule.tag.len > 0 and !std.mem.eql(u8, rule.tag, node.name)) continue;
            if (rule.class.len > 0 and !hasClass(cls, rule.class)) continue;
            if (rule.id.len > 0 and !std.mem.eql(u8, rule.id, id)) continue;
            if (declValue(rule.decls, name)) |v| found = v;
        }
        if (found) |v| return v;
        return r.d.attr(n, name);
    }

    fn length(r: *R, s: ?[]const u8, ref: f32, def: f32) f32 {
        const v = std.mem.trim(u8, s orelse return def, " \t\r\n");
        if (v.len == 0) return def;
        var end = v.len;
        while (end > 0 and std.ascii.isAlphabetic(v[end - 1]) or (end > 0 and v[end - 1] == '%')) end -= 1;
        const num = std.fmt.parseFloat(f32, v[0..end]) catch return def;
        const unit = v[end..];
        _ = r;
        const k: f32 = if (unit.len == 0 or std.mem.eql(u8, unit, "px")) 1 else if (std.mem.eql(u8, unit, "%")) ref / 100 else if (std.mem.eql(u8, unit, "pt")) 4.0 / 3.0 else if (std.mem.eql(u8, unit, "pc")) 16 else if (std.mem.eql(u8, unit, "mm")) 96.0 / 25.4 else if (std.mem.eql(u8, unit, "cm")) 96.0 / 2.54 else if (std.mem.eql(u8, unit, "in")) 96 else if (std.mem.eql(u8, unit, "em")) 16 else if (std.mem.eql(u8, unit, "ex")) 8 else 1;
        const out = num * k;
        return if (std.math.isFinite(out)) out else def;
    }

    fn diag(r: *R) f32 {
        return @sqrt((r.vw * r.vw + r.vh * r.vh) / 2);
    }

    fn paintOf(r: *R, s: []const u8, cur: Rgba, ref: *?u32) ?Paint {
        const v = std.mem.trim(u8, s, " \t\r\n");
        if (std.mem.eql(u8, v, "none")) return .none;
        if (std.mem.startsWith(u8, v, "url(")) {
            const c = std.mem.indexOfScalar(u8, v, ')') orelse return .none;
            var id = std.mem.trim(u8, v[4..c], " '\"");
            if (std.mem.startsWith(u8, id, "#")) id = id[1..];
            if (r.d.ids.get(id)) |gid| {
                const nm = r.d.nodes.items[gid].name;
                if (std.mem.eql(u8, nm, "linearGradient") or std.mem.eql(u8, nm, "radialGradient")) {
                    ref.* = gid;
                    return .none; // разрешится при отрисовке
                }
            }
            // запасной цвет после url(...)
            const rest = std.mem.trim(u8, v[c + 1 ..], " ");
            if (rest.len > 0) if (parseColor(rest, cur)) |col| return .{ .color = col };
            return .none;
        }
        if (parseColor(v, cur)) |col| return .{ .color = col };
        return null;
    }

    fn styleOf(r: *R, n: u32, parent: Style) !Style {
        var st = parent;
        st.opacity = parent.opacity;
        if (r.prop(n, "color")) |v| if (parseColor(v, parent.color)) |c| {
            st.color = c;
        };
        if (r.prop(n, "fill")) |v| {
            var ref: ?u32 = null;
            if (r.paintOf(v, st.color, &ref)) |p| {
                st.fill = p;
                st.fill_ref = ref;
            }
        }
        if (r.prop(n, "stroke")) |v| {
            var ref: ?u32 = null;
            if (r.paintOf(v, st.color, &ref)) |p| {
                st.stroke = p;
                st.stroke_ref = ref;
            }
        }
        if (r.prop(n, "stroke-width")) |v| st.stroke_w = @max(0, r.length(v, r.diag(), st.stroke_w));
        if (r.prop(n, "fill-opacity")) |v| st.fill_op = opacityOf(v, st.fill_op);
        if (r.prop(n, "stroke-opacity")) |v| st.stroke_op = opacityOf(v, st.stroke_op);
        if (r.prop(n, "opacity")) |v| st.opacity *= opacityOf(v, 1);
        if (r.prop(n, "fill-rule")) |v| st.evenodd = std.mem.eql(u8, std.mem.trim(u8, v, " "), "evenodd");
        if (r.prop(n, "stroke-linecap")) |v| st.cap = if (std.mem.indexOf(u8, v, "round") != null) 1 else if (std.mem.indexOf(u8, v, "square") != null) 2 else 0;
        if (r.prop(n, "stroke-linejoin")) |v| st.join = if (std.mem.indexOf(u8, v, "round") != null) 1 else if (std.mem.indexOf(u8, v, "bevel") != null) 2 else 0;
        if (r.prop(n, "stroke-miterlimit")) |v| st.miter = std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch st.miter;
        if (r.prop(n, "stroke-dasharray")) |v| {
            if (std.mem.eql(u8, std.mem.trim(u8, v, " "), "none")) st.dash = &.{} else {
                var arr = std.ArrayList(f32).init(r.a);
                var it = std.mem.tokenizeAny(u8, v, ", \t");
                while (it.next()) |t| try arr.append(@max(0, r.length(t, r.diag(), 0)));
                if (arr.items.len % 2 == 1) try arr.appendSlice(try r.a.dupe(f32, arr.items));
                st.dash = arr.items;
            }
        }
        if (r.prop(n, "stroke-dashoffset")) |v| st.dash_off = r.length(v, r.diag(), 0);
        if (r.prop(n, "visibility")) |v| st.visible = !(std.mem.eql(u8, std.mem.trim(u8, v, " "), "hidden") or std.mem.eql(u8, std.mem.trim(u8, v, " "), "collapse"));
        return st;
    }

    fn gradient(r: *R, gid: u32, ctm: Mat, bbox: [4]f32) !?Paint {
        // атрибуты — свои или по href; остановки — первые найденные по цепочке
        var chain: [8]u32 = undefined;
        var n_chain: usize = 0;
        var g: ?u32 = gid;
        while (g) |x| : (n_chain += 1) {
            if (n_chain == chain.len) break;
            chain[n_chain] = x;
            g = null;
            if (r.d.attr(x, "href")) |h| if (h.len > 1 and h[0] == '#') {
                g = r.d.ids.get(h[1..]);
            };
        }
        const get = struct {
            fn f(rr: *R, ch: []const u32, name: []const u8) ?[]const u8 {
                for (ch) |x| if (rr.d.attr(x, name)) |v| return v;
                return null;
            }
        }.f;
        var stops = std.ArrayList(Stop).init(r.a);
        for (chain[0..n_chain]) |x| {
            for (r.d.nodes.items[x].kids.items) |k| {
                if (!std.mem.eql(u8, r.d.nodes.items[k].name, "stop")) continue;
                var off = std.mem.trim(u8, r.prop(k, "offset") orelse "0", " ");
                var o: f32 = 0;
                if (std.mem.endsWith(u8, off, "%")) {
                    off = off[0 .. off.len - 1];
                    o = (std.fmt.parseFloat(f32, off) catch 0) / 100;
                } else o = std.fmt.parseFloat(f32, off) catch 0;
                o = std.math.clamp(o, 0, 1);
                if (stops.items.len > 0) o = @max(o, stops.items[stops.items.len - 1].off);
                var c = parseColor(r.prop(k, "stop-color") orelse "black", .{ 0, 0, 0, 1 }) orelse Rgba{ 0, 0, 0, 1 };
                c[3] *= opacityOf(r.prop(k, "stop-opacity") orelse "1", 1);
                try stops.append(.{ .off = o, .c = c });
            }
            if (stops.items.len > 0) break;
        }
        if (stops.items.len == 0) return .none;
        if (stops.items.len == 1) return .{ .color = stops.items[0].c };
        const radial = std.mem.eql(u8, r.d.nodes.items[gid].name, "radialGradient");
        const user = std.mem.eql(u8, std.mem.trim(u8, get(r, chain[0..n_chain], "gradientUnits") orelse "", " "), "userSpaceOnUse");
        const rw = if (user) r.vw else 1;
        const rh = if (user) r.vh else 1;
        const rd = if (user) r.diag() else 1;
        const frac = struct {
            fn f(rr: *R, s: ?[]const u8, ref: f32, def: f32, u: bool) f32 {
                const v = std.mem.trim(u8, s orelse return def, " ");
                if (!u and !std.mem.endsWith(u8, v, "%")) return std.fmt.parseFloat(f32, v) catch def;
                return rr.length(v, ref, def);
            }
        }.f;
        var gm = parseTransform(get(r, chain[0..n_chain], "gradientTransform") orelse "");
        if (!user) {
            const bw = bbox[2] - bbox[0];
            const bh = bbox[3] - bbox[1];
            if (bw <= 0 or bh <= 0) return .none;
            gm = (Mat{ .a = bw, .d = bh, .e = bbox[0], .f = bbox[1] }).mul(gm);
        }
        const full = ctm.mul(gm);
        const inv = full.inv() orelse return .none;
        const spread_s = std.mem.trim(u8, get(r, chain[0..n_chain], "spreadMethod") orelse "", " ");
        var gr = Grad{ .radial = radial, .inv = inv, .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .r = 0.5, .fx = 0.5, .fy = 0.5, .spread = if (std.mem.eql(u8, spread_s, "reflect")) 1 else if (std.mem.eql(u8, spread_s, "repeat")) 2 else 0, .stops = stops.items };
        const ch = chain[0..n_chain];
        if (!radial) {
            gr.x1 = frac(r, get(r, ch, "x1"), rw, 0, user);
            gr.y1 = frac(r, get(r, ch, "y1"), rh, 0, user);
            gr.x2 = frac(r, get(r, ch, "x2"), rw, if (user) rw else 1, user);
            gr.y2 = frac(r, get(r, ch, "y2"), rh, 0, user);
        } else {
            gr.x1 = frac(r, get(r, ch, "cx"), rw, if (user) rw / 2 else 0.5, user);
            gr.y1 = frac(r, get(r, ch, "cy"), rh, if (user) rh / 2 else 0.5, user);
            gr.r = frac(r, get(r, ch, "r"), rd, if (user) rd / 2 else 0.5, user);
            gr.fx = frac(r, get(r, ch, "fx"), rw, gr.x1, user);
            gr.fy = frac(r, get(r, ch, "fy"), rh, gr.y1, user);
            if (gr.r <= 0) return .{ .color = stops.items[stops.items.len - 1].c };
        }
        return .{ .grad = gr };
    }

    fn draw(r: *R, n: u32, parent: Style, ctm: Mat) Error!void {
        const node = &r.d.nodes.items[n];
        const name = node.name;
        if (r.prop(n, "display")) |v| if (std.mem.eql(u8, std.mem.trim(u8, v, " "), "none")) return;
        const skip = [_][]const u8{ "defs", "clipPath", "mask", "pattern", "filter", "text", "image", "metadata", "title", "desc", "foreignObject", "script", "style", "linearGradient", "radialGradient", "symbol", "marker", "switch_" };
        for (skip) |s| if (std.mem.eql(u8, name, s)) return;
        const st = styleOf(r, n, parent) catch return error.OutOfMemory;
        var m = ctm;
        if (r.d.attr(n, "transform")) |t| m = m.mul(parseTransform(t));
        if (std.mem.eql(u8, name, "g") or std.mem.eql(u8, name, "a") or std.mem.eql(u8, name, "switch")) {
            for (node.kids.items) |k| try r.draw(k, st, m);
            return;
        }
        if (std.mem.eql(u8, name, "svg")) {
            // вложенный svg: x, y, viewBox
            const x = r.length(r.d.attr(n, "x"), r.vw, 0);
            const y = r.length(r.d.attr(n, "y"), r.vh, 0);
            m = m.mul(translate(x, y));
            if (r.d.attr(n, "viewBox")) |vb| {
                const w = r.length(r.d.attr(n, "width"), r.vw, r.vw);
                const h = r.length(r.d.attr(n, "height"), r.vh, r.vh);
                m = m.mul(viewBoxMat(vb, w, h, r.d.attr(n, "preserveAspectRatio")) orelse return);
            }
            for (node.kids.items) |k| try r.draw(k, st, m);
            return;
        }
        if (std.mem.eql(u8, name, "use")) {
            const h = r.d.attr(n, "href") orelse return;
            if (h.len < 2 or h[0] != '#') return;
            const target = r.d.ids.get(h[1..]) orelse return;
            if (r.use_depth >= max_use_depth) return;
            r.use_depth += 1;
            defer r.use_depth -= 1;
            m = m.mul(translate(r.length(r.d.attr(n, "x"), r.vw, 0), r.length(r.d.attr(n, "y"), r.vh, 0)));
            const tn = &r.d.nodes.items[target];
            if (std.mem.eql(u8, tn.name, "symbol")) {
                const ts = styleOf(r, target, st) catch return error.OutOfMemory;
                if (r.d.attr(target, "viewBox")) |vb| {
                    const w = r.length(r.d.attr(n, "width"), r.vw, r.vw);
                    const hh = r.length(r.d.attr(n, "height"), r.vh, r.vh);
                    m = m.mul(viewBoxMat(vb, w, hh, r.d.attr(target, "preserveAspectRatio")) orelse return);
                }
                for (tn.kids.items) |k| try r.draw(k, ts, m);
            } else try r.draw(target, st, m);
            return;
        }
        // фигуры
        var path = Path{ .a = r.a, .m = m, .tol = 0.15, .points = &r.points };
        const L = struct {
            fn f(rr: *R, nn: u32, at: []const u8, ref: f32) f32 {
                return rr.length(rr.d.attr(nn, at), ref, 0);
            }
        }.f;
        var bbox_user: [4]f32 = .{ 0, 0, 0, 0 };
        if (std.mem.eql(u8, name, "path")) {
            buildPathData(&path, r.d.attr(n, "d") orelse return) catch |e| return if (e == error.TooBig) error.TooBig else error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "rect")) {
            const x = L(r, n, "x", r.vw);
            const y = L(r, n, "y", r.vh);
            const w = L(r, n, "width", r.vw);
            const h = L(r, n, "height", r.vh);
            if (w <= 0 or h <= 0) return;
            var rx = L(r, n, "rx", r.vw);
            var ry = L(r, n, "ry", r.vh);
            if (r.d.attr(n, "rx") == null) rx = ry;
            if (r.d.attr(n, "ry") == null) ry = rx;
            rx = @min(rx, w / 2);
            ry = @min(ry, h / 2);
            path_rect: {
                if (rx <= 0 or ry <= 0) {
                    path.moveTo(.{ .x = x, .y = y }) catch return error.OutOfMemory;
                    path.lineTo(.{ .x = x + w, .y = y }) catch return error.OutOfMemory;
                    path.lineTo(.{ .x = x + w, .y = y + h }) catch return error.OutOfMemory;
                    path.lineTo(.{ .x = x, .y = y + h }) catch return error.OutOfMemory;
                    path.close();
                    break :path_rect;
                }
                const d = std.fmt.allocPrint(r.a, "M{d} {d}H{d}A{d} {d} 0 0 1 {d} {d}V{d}A{d} {d} 0 0 1 {d} {d}H{d}A{d} {d} 0 0 1 {d} {d}V{d}A{d} {d} 0 0 1 {d} {d}Z", .{
                    x + rx, y, x + w - rx, rx, ry, x + w, y + ry, y + h - ry, rx, ry, x + w - rx, y + h, x + rx, rx, ry, x, y + h - ry, y + ry, rx, ry, x + rx, y,
                }) catch return error.OutOfMemory;
                buildPathData(&path, d) catch |e| return if (e == error.TooBig) error.TooBig else error.OutOfMemory;
            }
            bbox_user = .{ x, y, x + w, y + h };
        } else if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
            const cx = L(r, n, "cx", r.vw);
            const cy = L(r, n, "cy", r.vh);
            var rx: f32 = undefined;
            var ry: f32 = undefined;
            if (name[0] == 'c') {
                rx = L(r, n, "r", r.diag());
                ry = rx;
            } else {
                rx = L(r, n, "rx", r.vw);
                ry = L(r, n, "ry", r.vh);
            }
            ellipsePath(&path, cx, cy, rx, ry) catch |e| return if (e == error.TooBig) error.TooBig else error.OutOfMemory;
            bbox_user = .{ cx - rx, cy - ry, cx + rx, cy + ry };
        } else if (std.mem.eql(u8, name, "line")) {
            const x1 = L(r, n, "x1", r.vw);
            const y1 = L(r, n, "y1", r.vh);
            const x2 = L(r, n, "x2", r.vw);
            const y2 = L(r, n, "y2", r.vh);
            path.moveTo(.{ .x = x1, .y = y1 }) catch return error.OutOfMemory;
            path.lineTo(.{ .x = x2, .y = y2 }) catch return error.OutOfMemory;
            bbox_user = .{ @min(x1, x2), @min(y1, y2), @max(x1, x2), @max(y1, y2) };
        } else if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
            var ns = Nums{ .s = r.d.attr(n, "points") orelse return };
            var first = true;
            while (true) {
                const x = ns.num() orelse break;
                const y = ns.num() orelse break;
                if (first) path.moveTo(.{ .x = x, .y = y }) catch return error.OutOfMemory else path.lineTo(.{ .x = x, .y = y }) catch |e| return if (e == error.TooBig) error.TooBig else error.OutOfMemory;
                first = false;
            }
            if (name[4] == 'g') path.close();
        } else return; // прочие элементы не рисуются
        if (!st.visible or path.subs.items.len == 0) return;

        // рамка фигуры (для градиентов objectBoundingBox): по точкам в пространстве пользователя
        if (bbox_user[2] <= bbox_user[0] or bbox_user[3] <= bbox_user[1]) {
            if (m.inv()) |mi| {
                var b = [4]f32{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
                for (path.subs.items) |s| for (s.pts.items) |p| {
                    const u = mi.apply(p);
                    b = .{ @min(b[0], u.x), @min(b[1], u.y), @max(b[2], u.x), @max(b[3], u.y) };
                };
                bbox_user = b;
            }
        }
        var fill_paint = st.fill;
        if (st.fill_ref) |g| fill_paint = (r.gradient(g, m, bbox_user) catch return error.OutOfMemory) orelse .none;
        var stroke_paint = st.stroke;
        if (st.stroke_ref) |g| stroke_paint = (r.gradient(g, m, bbox_user) catch return error.OutOfMemory) orelse .none;

        // заливка (у line и polyline — тоже: подпути замыкаются)
        if (fill_paint != .none and !std.mem.eql(u8, name, "line")) {
            var polys = std.ArrayList([]const Pt).init(r.a);
            for (path.subs.items) |s| polys.append(s.pts.items) catch return error.OutOfMemory;
            fill(r.cv, r.a, polys.items, st.evenodd, &fill_paint, st.fill_op * st.opacity) catch return error.OutOfMemory;
        }
        if (stroke_paint != .none and st.stroke_w > 0) {
            const sw = st.stroke_w * m.scale();
            var polys = std.ArrayList([]const Pt).init(r.a);
            const sk = Stroke{ .w = @max(sw, 0.01), .cap = st.cap, .join = st.join, .miter = st.miter };
            for (path.subs.items) |s| {
                if (st.dash.len > 0) {
                    var parts = std.ArrayList([]Pt).init(r.a);
                    const scaled = r.a.alloc(f32, st.dash.len) catch return error.OutOfMemory;
                    for (scaled, st.dash) |*o, d| o.* = d * m.scale();
                    dashes(r.a, s.pts.items, s.closed, scaled, st.dash_off * m.scale(), &parts) catch |e| return if (e == error.TooBig) error.TooBig else error.OutOfMemory;
                    for (parts.items) |pp| strokePolys(r.a, pp, false, sk, &polys) catch return error.OutOfMemory;
                } else strokePolys(r.a, s.pts.items, s.closed, sk, &polys) catch return error.OutOfMemory;
            }
            fill(r.cv, r.a, polys.items, false, &stroke_paint, st.stroke_op * st.opacity) catch return error.OutOfMemory;
        }
    }
};

fn opacityOf(s: []const u8, def: f32) f32 {
    var v = std.mem.trim(u8, s, " \t\r\n");
    var div: f32 = 1;
    if (std.mem.endsWith(u8, v, "%")) {
        v = v[0 .. v.len - 1];
        div = 100;
    }
    const x = std.fmt.parseFloat(f32, v) catch return def;
    return std.math.clamp(x / div, 0, 1);
}

/// viewBox → матрица в окно w×h с preserveAspectRatio (по умолчанию xMidYMid meet).
fn viewBoxMat(vb: []const u8, w: f32, h: f32, par: ?[]const u8) ?Mat {
    var ns = Nums{ .s = vb };
    const x = ns.num() orelse return null;
    const y = ns.num() orelse return null;
    const vw = ns.num() orelse return null;
    const vh = ns.num() orelse return null;
    if (vw <= 0 or vh <= 0) return null;
    var sx = w / vw;
    var sy = h / vh;
    const p = std.mem.trim(u8, par orelse "xMidYMid meet", " ");
    if (std.mem.startsWith(u8, p, "none")) return (Mat{ .a = sx, .d = sy }).mul(translate(-x, -y));
    const slice = std.mem.indexOf(u8, p, "slice") != null;
    const s = if (slice) @max(sx, sy) else @min(sx, sy);
    sx = s;
    sy = s;
    var tx: f32 = 0;
    var ty: f32 = 0;
    const ax: f32 = if (std.mem.indexOf(u8, p, "xMin") != null) 0 else if (std.mem.indexOf(u8, p, "xMax") != null) 1 else 0.5;
    const ay: f32 = if (std.mem.indexOf(u8, p, "YMin") != null) 0 else if (std.mem.indexOf(u8, p, "YMax") != null) 1 else 0.5;
    tx = (w - vw * s) * ax;
    ty = (h - vh * s) * ay;
    return (Mat{ .a = sx, .d = sy, .e = tx, .f = ty }).mul(translate(-x, -y));
}

/// Свой размер картинки: width/height, иначе viewBox, иначе 300×150.
pub fn intrinsic(a: std.mem.Allocator, bytes: []const u8) ?[2]f32 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var d = parseXml(arena.allocator(), bytes) catch return null;
    const root = findRoot(&d) orelse return null;
    return rootSize(&d, root);
}

fn findRoot(d: *Doc) ?u32 {
    for (d.nodes.items[0].kids.items) |k| if (std.mem.eql(u8, d.nodes.items[k].name, "svg")) return k;
    return null;
}

fn rootSize(d: *Doc, root: u32) [2]f32 {
    var dummy = R{ .a = d.a, .d = d, .rules = &.{}, .cv = undefined, .vw = 0, .vh = 0 };
    var vbw: f32 = 0;
    var vbh: f32 = 0;
    if (d.attr(root, "viewBox")) |vb| {
        var ns = Nums{ .s = vb };
        _ = ns.num();
        _ = ns.num();
        vbw = ns.num() orelse 0;
        vbh = ns.num() orelse 0;
    }
    const ws = d.attr(root, "width");
    const hs = d.attr(root, "height");
    const pct_w = ws != null and std.mem.endsWith(u8, std.mem.trim(u8, ws.?, " "), "%");
    const pct_h = hs != null and std.mem.endsWith(u8, std.mem.trim(u8, hs.?, " "), "%");
    var w = if (ws != null and !pct_w) dummy.length(ws, 0, 0) else 0;
    var h = if (hs != null and !pct_h) dummy.length(hs, 0, 0) else 0;
    if (w <= 0 and h <= 0) {
        if (vbw > 0 and vbh > 0) {
            w = vbw;
            h = vbh;
        } else {
            w = 300;
            h = 150;
        }
    } else if (w <= 0) {
        w = if (vbh > 0) h * vbw / vbh else 300;
    } else if (h <= 0) {
        h = if (vbw > 0) w * vbh / vbw else 150;
    }
    return .{ w, h };
}

/// Растеризация: свой размер, вписанный в место `box_w`×`box_h` без увеличения.
pub fn render(a: std.mem.Allocator, bytes: []const u8, box_w: u32, box_h: u32) Error!Image {
    return renderFit(a, bytes, box_w, box_h, false);
}

/// То же; `grow` — вписывать и с увеличением (для сверки с браузером).
pub fn renderFit(a: std.mem.Allocator, bytes: []const u8, box_w: u32, box_h: u32, grow: bool) Error!Image {
    if (!looksLike(bytes)) return error.NotSvg;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var d = try parseXml(aa, bytes);
    const root = findRoot(&d) orelse return error.Damaged;
    const size = rootSize(&d, root);
    if (!(size[0] > 0 and size[1] > 0 and std.math.isFinite(size[0] + size[1]))) return error.Damaged;
    // вписать в место без увеличения
    const fit_sc = @min(@as(f32, @floatFromInt(box_w)) / size[0], @as(f32, @floatFromInt(box_h)) / size[1]);
    var sc: f32 = if (grow) fit_sc else @min(1, fit_sc);
    if (!std.math.isFinite(sc) or sc <= 0) sc = 1;
    const ow: u32 = @intCast(toInt(@round(size[0] * sc), 1, box_w));
    const oh: u32 = @intCast(toInt(@round(size[1] * sc), 1, box_h));
    var cv = Canvas{ .w = ow, .h = oh, .px = try aa.alloc(f32, @as(usize, ow) * oh * 4), .cover = try aa.alloc(f32, ow + 2) };
    @memset(cv.px, 0);
    @memset(cv.cover, 0);
    var r = R{ .a = aa, .d = &d, .rules = parseCss(aa, d.css.items) catch return error.OutOfMemory, .cv = &cv, .vw = size[0], .vh = size[1] };
    var m = Mat{ .a = @as(f32, @floatFromInt(ow)) / size[0], .d = @as(f32, @floatFromInt(oh)) / size[1] };
    if (d.attr(root, "viewBox")) |vb| if (viewBoxMat(vb, size[0], size[1], d.attr(root, "preserveAspectRatio"))) |vm| {
        m = m.mul(vm);
        var ns = Nums{ .s = vb };
        _ = ns.num();
        _ = ns.num();
        r.vw = ns.num() orelse size[0];
        r.vh = ns.num() orelse size[1];
    };
    const st = r.styleOf(root, .{}) catch return error.OutOfMemory;
    for (d.nodes.items[root].kids.items) |k| try r.draw(k, st, m);
    // в RGBA8 без умножения на альфу
    const px = try a.alloc(u8, @as(usize, ow) * oh * 4);
    for (0..@as(usize, ow) * oh) |i| {
        const s = cv.px[i * 4 ..][0..4];
        const al = std.math.clamp(s[3], 0, 1);
        if (!(al > 0)) {
            px[i * 4 ..][0..4].* = .{ 0, 0, 0, 0 };
            continue;
        }
        for (0..3) |k| px[i * 4 + k] = @intCast(toInt(@round(s[k] / al * 255), 0, 255));
        px[i * 4 + 3] = @intCast(toInt(@round(al * 255), 0, 255));
    }
    return .{ .w = ow, .h = oh, .px = px };
}

test "svg: фигуры, цвета, вписывание" {
    const a = std.testing.allocator;
    const src =
        \\<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 200 100">
        \\<style>.b{fill:#0000ff}</style>
        \\<rect width="100" height="100" fill="red"/><rect class="b" x="100" width="100" height="100"/>
        \\<circle cx="50" cy="50" r="20" fill="rgb(0,255,0)" stroke="white" stroke-width="4"/></svg>
    ;
    const img = try render(a, src, 800, 600);
    defer a.free(img.px);
    try std.testing.expectEqual(@as(u32, 100), img.w);
    try std.testing.expectEqual(@as(u32, 50), img.h);
    const px = struct {
        fn f(im: Image, x: usize, y: usize) [4]u8 {
            return im.px[(y * im.w + x) * 4 ..][0..4].*;
        }
    }.f;
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(img, 2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(img, 90, 40));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(img, 25, 25));
    // большая — вписывается
    const big = try render(a, "<svg width='4000' height='1000'><rect width='10' height='10'/></svg>", 800, 600);
    defer a.free(big.px);
    try std.testing.expectEqual(@as(u32, 800), big.w);
    try std.testing.expectEqual(@as(u32, 200), big.h);
}

test "svg: враждебный ввод" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotSvg, render(a, "<html/>", 800, 600));
    const cases = [_][]const u8{
        "<svg",
        "<svg><path d='M 1e39 1e39 L -1e39 0 Z'/></svg>",
        "<svg><path d='M0 0 A 0 0 0 1 1 10 10 a 1e-30 1e-30 0 1 1 1 1'/></svg>",
        "<svg><use href='#a' id='a'/></svg>",
        "<svg><g id='a'><use href='#a'/><use href='#a'/></g></svg>",
        "<!DOCTYPE svg [<!ENTITY a 'aaaa'>]><svg><rect width='&a;' height='1'/></svg>",
        "<svg viewBox='0 0 0 0'><rect width='1' height='1'/></svg>",
        "<svg width='-5' height='nan'><circle r='1e30'/></svg>",
        "<svg><path d='M0 0 L 10 10' stroke='red' stroke-dasharray='0 0'/><path d='M0 0 L 100 100' stroke='red' stroke-dasharray='0.00001'/></svg>",
    };
    for (cases) |c| if (render(a, c, 200, 200)) |im| a.free(im.px) else |_| {};
    var prng = std.Random.DefaultPrng.init(4);
    const rnd = prng.random();
    const alphabet = "<svg pathrect d='M0 1 L2 3 C4 5 6 7 8 9 A1 1 0 1 1 Z' fill=stroke# >/use href#a g transform=rotate(30) scale(2) 0.5-.";
    var buf: [400]u8 = undefined;
    for (0..2000) |_| {
        @memcpy(buf[0..5], "<svg ");
        const n = rnd.intRangeAtMost(usize, 5, buf.len);
        for (buf[5..n]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        if (render(a, buf[0..n], 120, 120)) |im| a.free(im.px) else |_| {}
    }
}
