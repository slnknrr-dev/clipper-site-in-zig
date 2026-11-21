//! Темы и режимы. `t = тема[-режим]`: тема из flibusta|samlib|proza|nepomn,
//! режим light|dark|time; одни light|dark|time — тема по умолчанию.
//!
//! Цвета отделены от разметки: страница не зависит от режима, а стили
//! отдаются по `/css/{тема}-{режим}.css` — CSS-переменные палитры и правила
//! темы. Так HTML одной темы одинаков для всех режимов и хорошо кэшируется.
//! Градиенты шапки — 1-пиксельные BMP по `/g/{высота}/{цвета}.bmp`.

const std = @import("std");
const W = @import("out.zig").W;

pub const Base = enum { flibusta, samlib, proza, nepomn };
pub const Mode = enum { auto, light, dark, time };
pub const Theme = struct { base: Base, mode: Mode };

/// Что о темах решил администратор в панели: тема и режим по умолчанию, какие
/// темы и режимы посетитель вправе выбрать сам (`t=`) и видит ли он настройку
/// оформления вообще. Тема и режим по умолчанию разрешены всегда.
pub const Look = struct {
    base: Base = .flibusta,
    mode: Mode = .auto,
    bases: u4 = 15,
    modes: u4 = 15,
    show: bool = true,

    pub fn baseOn(l: Look, b: Base) bool {
        return b == l.base or (l.show and l.bases & (@as(u4, 1) << @intFromEnum(b)) != 0);
    }
    pub fn modeOn(l: Look, m: Mode) bool {
        return m == l.mode or (l.show and l.modes & (@as(u4, 1) << @intFromEnum(m)) != 0);
    }
};

/// Тема посетителя: его `t`, урезанное до разрешённого. Режим без названия в
/// `t` — режим по умолчанию; `auto` можно назвать явно (`samlib-auto`).
pub fn pick(t: []const u8, look: Look) Theme {
    var th = Theme{ .base = look.base, .mode = look.mode };
    if (t.len == 0) return th;
    var it = std.mem.splitScalar(u8, t, '-');
    const a = it.next() orelse "";
    const b = it.next() orelse "";
    if (modeOf(a)) |m| {
        if (look.modeOn(m)) th.mode = m;
        return th;
    }
    if (baseOf(a)) |x| if (look.baseOn(x)) {
        th.base = x;
    };
    if (modeOf(b)) |m| if (look.modeOn(m)) {
        th.mode = m;
    };
    return th;
}

/// Значение `t` для темы и режима: режим пишется, только если он не по умолчанию.
pub fn value(w: *W, b: Base, m: Mode, look: Look) void {
    w.raw(@tagName(b));
    if (m != look.mode) {
        w.byte('-');
        w.raw(@tagName(m));
    }
}

fn modeOf(s: []const u8) ?Mode {
    if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(s, "light")) return .light;
    if (std.ascii.eqlIgnoreCase(s, "dark")) return .dark;
    if (std.ascii.eqlIgnoreCase(s, "time")) return .time;
    return null;
}

pub fn baseOf(s: []const u8) ?Base {
    inline for (@typeInfo(Base).@"enum".fields) |f| if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(Base, f.name);
    return null;
}

pub fn parse(t: ?[]const u8, default: Base) Theme {
    const s = t orelse return .{ .base = default, .mode = .auto };
    if (s.len == 0) return .{ .base = default, .mode = .auto };
    var it = std.mem.splitScalar(u8, s, '-');
    const a = it.next() orelse "";
    const b = it.next() orelse "";
    if (modeOf(a)) |m| return .{ .base = default, .mode = m };
    return .{ .base = baseOf(a) orelse default, .mode = modeOf(b) orelse .auto };
}

/// `time` → светлая с 7 до 20 часов.
pub fn resolve(mode: Mode, hour: u8) Mode {
    if (mode == .time) return if (hour >= 7 and hour < 20) .light else .dark;
    return mode;
}

const KV = struct { []const u8, []const u8 };
const Pal = struct { vars: []const KV, g_header: []const u8 = "", g_tab: []const u8 = "", g_footer: []const u8 = "" };

// Светлые палитры сняты с настоящих сайтов (макет, ноябрь 2026).
const flibusta_light = Pal{ .vars = &.{
    .{ "bg", "#fdfeff" },          .{ "fg", "#393939" },        .{ "link", "#5294c1" },    .{ "vlink", "#5294c1" },         .{ "page", "#f3f7fb" },
    .{ "tab", "#24375b" },         .{ "tabBorder", "#96b4d5" }, .{ "blockHead", "#e5ecf5" }, .{ "blockHeadFg", "#6c7a8d" }, .{ "blockBorder", "#d1dbec" },
    .{ "node", "#f7faff" },        .{ "nodeBorder", "#dadce0" }, .{ "slogan", "#a4bedd" },  .{ "title", "#333333" },         .{ "mission", "#bcd1ea" },
    .{ "missionBorder", "#96adc8" }, .{ "odd", "#ffffff" },      .{ "even", "#fbfcfe" },    .{ "quote", "#f6f6f6" },         .{ "muted", "#666666" },
    .{ "input", "#fbfcfe" },
}, .g_header = "83a5c9-abcbef-b4d0f0-cddef1-8eafd4-83a5cd-799dc7-7399c3-77a0cf", .g_tab = "c1dbf6-cae0f7-d3e4f7-d0e1f5", .g_footer = "a6b9cd-cedff0-cddff2-c6daef-bfd4ec-738ba8" };
const flibusta_dark = Pal{ .vars = &.{
    .{ "bg", "#161c24" },          .{ "fg", "#cdd5df" },        .{ "link", "#7fb6e0" },    .{ "vlink", "#7fb6e0" },         .{ "page", "#10151b" },
    .{ "tab", "#dce8f8" },         .{ "tabBorder", "#3a5576" }, .{ "blockHead", "#1f2a38" }, .{ "blockHeadFg", "#9fb0c6" }, .{ "blockBorder", "#2c3b4f" },
    .{ "node", "#1a222c" },        .{ "nodeBorder", "#2c3646" }, .{ "slogan", "#7f9bbd" },  .{ "title", "#e2e8f0" },         .{ "mission", "#22344b" },
    .{ "missionBorder", "#36506f" }, .{ "odd", "#161c24" },      .{ "even", "#1a212a" },    .{ "quote", "#1f262f" },         .{ "muted", "#8a96a6" },
    .{ "input", "#1a222c" },
}, .g_header = "1d2c40-2b4566-2f4a6c-35527a-24395a-1f3352-1b2e4a", .g_tab = "2a4566-1f3352", .g_footer = "1f3352-182840-121e30" };
const samlib_light = Pal{ .vars = &.{
    .{ "bg", "#e9e9e9" },   .{ "fg", "#000000" },  .{ "link", "#0000ee" }, .{ "vlink", "#551a8b" }, .{ "grey", "#555555" }, .{ "head", "#e0e0e0" },  .{ "red", "#f1c9c9" },
    .{ "green", "#c9f1c9" }, .{ "blue", "#c9c9f1" }, .{ "pink", "#ffb9b9" }, .{ "mint", "#c9f1d9" }, .{ "hr", "#808080" },   .{ "muted", "#555555" }, .{ "input", "#ffffff" },
} };
const samlib_dark = Pal{ .vars = &.{
    .{ "bg", "#1e1e1e" },   .{ "fg", "#d6d6d6" },  .{ "link", "#8ab4f8" }, .{ "vlink", "#c58af9" }, .{ "grey", "#a0a0a0" }, .{ "head", "#2c2c2c" },  .{ "red", "#4a2a2a" },
    .{ "green", "#294229" }, .{ "blue", "#2a2a4a" }, .{ "pink", "#5a2c2c" }, .{ "mint", "#264236" }, .{ "hr", "#707070" },   .{ "muted", "#9a9a9a" }, .{ "input", "#2a2a2a" },
} };
const proza_light = Pal{ .vars = &.{
    .{ "bg", "#ffffff" },   .{ "fg", "#000000" },    .{ "link", "#000080" }, .{ "vlink", "#000080" }, .{ "menu", "#404040" },  .{ "head", "#505050" },  .{ "logo", "#60b050" },
    .{ "logo2", "#aaaaaa" }, .{ "foot", "#f4f4f4" }, .{ "footFg", "#808080" }, .{ "line", "#cccccc" }, .{ "muted", "#808080" }, .{ "text2", "#303030" }, .{ "input", "#ffffff" },
} };
const proza_dark = Pal{ .vars = &.{
    .{ "bg", "#151515" },   .{ "fg", "#dddddd" },    .{ "link", "#9fb4ff" }, .{ "vlink", "#9fb4ff" }, .{ "menu", "#c0c0c0" },  .{ "head", "#b8b8b8" },  .{ "logo", "#4f9a41" },
    .{ "logo2", "#666666" }, .{ "foot", "#1f1f1f" }, .{ "footFg", "#909090" }, .{ "line", "#3a3a3a" }, .{ "muted", "#909090" }, .{ "text2", "#cfcfcf" }, .{ "input", "#1f1f1f" },
} };
const nepomn_light = Pal{ .vars = &.{
    .{ "bg", "#dedede" },    .{ "fg", "#000000" },  .{ "link", "#416679" },  .{ "vlink", "#416679" },   .{ "hover", "#99ccff" },    .{ "accent", "#800000" }, .{ "accentHover", "#c04040" },
    .{ "panel", "#ffffff" }, .{ "sub", "#eeeeee" }, .{ "subFg", "#6a6a6a" }, .{ "rowDark", "#eeeeee" }, .{ "rowLight", "#ffffff" }, .{ "muted", "#6a6a6a" },  .{ "input", "#ffffff" },
} };
const nepomn_dark = Pal{ .vars = &.{
    .{ "bg", "#262626" },    .{ "fg", "#dcdcdc" },  .{ "link", "#8fb8cc" },  .{ "vlink", "#8fb8cc" },   .{ "hover", "#c0e0ff" },    .{ "accent", "#d06060" }, .{ "accentHover", "#f08080" },
    .{ "panel", "#1a1a1a" }, .{ "sub", "#222222" }, .{ "subFg", "#a0a0a0" }, .{ "rowDark", "#222222" }, .{ "rowLight", "#1a1a1a" }, .{ "muted", "#9a9a9a" },  .{ "input", "#222222" },
} };

// ───────────── цвета: главный (-c) и фирменный (-b) ─────────────
//
// Палитры выше сняты с настоящих сайтов и записаны готовыми цветами. Но почти
// все оттенки темы — производные от одного главного цвета: у flibusta это
// голубой ссылок, от которого посветлее — фон блоков, потемнее — вкладки,
// почти белый — фон страницы. Поэтому каждый цвет палитры хранит не только
// себя, но и своё отношение к главному: сдвиг тона, отношение насыщенности и
// место по светлоте. Флаг -c задаёт новый главный цвет, и вся палитра
// пересчитывается так, чтобы отношения сохранились. Флаг -b — то же для
// фирменного цвета (логотип proza, акцент nepomn).
//
// Главный цвет по умолчанию (`Defaults.core`) — тот, относительно которого
// палитра снята. Задать его флагом — получить ровно исходную палитру: тогда
// пересчёт не выполняется вовсе.
//
// Что не пересчитывается: серые и почти серые цвета (текст, белый фон,
// рамки без оттенка) и смысловые цвета (красный и зелёный маркеры samlib).

pub const Rgb = [3]u8;

pub const Defaults = struct { core: Rgb, brand: ?Rgb = null };

/// Главный и фирменный цвета тем по умолчанию — те, от которых сняты палитры.
pub const defaults = [_]Defaults{
    .{ .core = .{ 0x52, 0x94, 0xc1 } }, // flibusta: цвет ссылок
    .{ .core = .{ 0x00, 0x00, 0xee } }, // samlib: цвет ссылок
    .{ .core = .{ 0x00, 0x00, 0x80 }, .brand = .{ 0x60, 0xb0, 0x50 } }, // proza: ссылки; зелёный логотип
    .{ .core = .{ 0x41, 0x66, 0x79 }, .brand = .{ 0x80, 0x00, 0x00 } }, // nepomn: ссылки; бордовый акцент
};

const Role = enum { core, brand, fixed };

/// Роль цвета палитры: от чего он считается.
fn role(base: Base, key: []const u8) Role {
    const eq = std.mem.eql;
    return switch (base) {
        .flibusta => .core,
        .samlib => if (eq(u8, key, "red") or eq(u8, key, "green") or eq(u8, key, "pink") or eq(u8, key, "mint") or eq(u8, key, "blue")) .fixed else .core,
        .proza => if (eq(u8, key, "logo")) .brand else .core,
        .nepomn => if (eq(u8, key, "accent") or eq(u8, key, "accentHover")) .brand else .core,
    };
}

pub fn parseColor(s_in: []const u8) ?Rgb {
    const s = if (s_in.len > 0 and s_in[0] == '#') s_in[1..] else s_in;
    var c: Rgb = undefined;
    if (s.len == 6) {
        _ = std.fmt.hexToBytes(&c, s) catch return null;
        return c;
    }
    if (s.len == 3) {
        for (s, 0..) |ch, i| {
            const v = std.fmt.charToDigit(ch, 16) catch return null;
            c[i] = v * 17;
        }
        return c;
    }
    return null;
}

const Hsl = struct { h: f32, s: f32, l: f32 };

fn toHsl(c: Rgb) Hsl {
    const r = @as(f32, @floatFromInt(c[0])) / 255;
    const g = @as(f32, @floatFromInt(c[1])) / 255;
    const b = @as(f32, @floatFromInt(c[2])) / 255;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const l = (mx + mn) / 2;
    const d = mx - mn;
    if (d == 0) return .{ .h = 0, .s = 0, .l = l };
    const s = d / (1 - @abs(2 * l - 1));
    var h: f32 = if (mx == r) @mod((g - b) / d, 6) else if (mx == g) (b - r) / d + 2 else (r - g) / d + 4;
    h *= 60;
    return .{ .h = h, .s = @min(s, 1), .l = l };
}

fn fromHsl(x: Hsl) Rgb {
    const c = (1 - @abs(2 * x.l - 1)) * x.s;
    const hp = @mod(x.h, 360) / 60;
    const xx = c * (1 - @abs(@mod(hp, 2) - 1));
    const m = x.l - c / 2;
    const rgb: [3]f32 = if (hp < 1) .{ c, xx, 0 } else if (hp < 2) .{ xx, c, 0 } else if (hp < 3) .{ 0, c, xx } else if (hp < 4) .{ 0, xx, c } else if (hp < 5) .{ xx, 0, c } else .{ c, 0, xx };
    var out: Rgb = undefined;
    for (rgb, 0..) |v, i| out[i] = @intFromFloat(std.math.clamp(@round((v + m) * 255), 0, 255));
    return out;
}

/// Почти серый цвет: у него нет тона, который можно было бы сдвинуть.
fn neutral(c: Rgb) bool {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2])) <= 6;
}

/// Цвет палитры при главном цвете `to` вместо `from`. Тон сдвигается на ту же
/// величину, насыщенность меняется в том же отношении. Светлота в светлой
/// палитре растягивается так, что светлота главного цвета переходит в новую, а
/// чёрный и белый остаются на местах; в тёмной палитре светлота не трогается —
/// иначе тёмная тема перестала бы быть тёмной.
pub fn recolor(c: Rgb, from: Rgb, to: Rgb, dark: bool) Rgb {
    if (neutral(c) or std.mem.eql(u8, &from, &to)) return c;
    const x = toHsl(c);
    const f = toHsl(from);
    const t = toHsl(to);
    var y = x;
    y.h = @mod(x.h + (t.h - f.h) + 360, 360);
    y.s = if (f.s > 0) std.math.clamp(x.s * t.s / f.s, 0, 1) else t.s;
    if (!dark) {
        y.l = if (x.l <= f.l)
            (if (f.l > 0) x.l * t.l / f.l else x.l)
        else
            (if (f.l < 1) 1 - (1 - x.l) * (1 - t.l) / (1 - f.l) else x.l);
    }
    return fromHsl(y);
}

const max_vars = 24;
const Live = struct {
    kv: [max_vars]KV = undefined,
    hex: [max_vars][7]u8 = undefined,
    grad: [3][160]u8 = undefined,
    pal: Pal = .{ .vars = &.{} },
};
var live: [4][2]Live = undefined;
var live_ready = false;
var chosen: [4]Defaults = defaults;

fn hexOf(buf: *[7]u8, c: Rgb) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c[0], c[1], c[2] }) catch unreachable;
}

/// Градиент «rrggbb-rrggbb-…», пересчитанный от главного цвета.
fn recolorGrad(out: []u8, spec: []const u8, from: Rgb, to: Rgb, dark: bool) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, '-');
    while (it.next()) |s| {
        const c = parseColor(s) orelse continue;
        const r = recolor(c, from, to, dark);
        if (n > 0) {
            out[n] = '-';
            n += 1;
        }
        _ = std.fmt.bufPrint(out[n..][0..6], "{x:0>2}{x:0>2}{x:0>2}", .{ r[0], r[1], r[2] }) catch unreachable;
        n += 6;
    }
    return out[0..n];
}

/// Фирменный цвет, когда задан только главный: контрастный ему — тон напротив
/// по кругу, насыщенность не ниже средней, а светлота — как у фирменного цвета
/// темы по умолчанию, чтобы логотип оставался читаемым на своём месте.
pub fn contrastBrand(core: Rgb, default_brand: Rgb) Rgb {
    const c = toHsl(core);
    const d = toHsl(default_brand);
    return fromHsl(.{ .h = @mod(c.h + 180, 360), .s = @max(c.s, 0.45), .l = d.l });
}

/// Главный (`core`) и фирменный (`brand`) цвета сайта: флаги -c и -b. null —
/// цвета темы по умолчанию; задан только главный — фирменный вычисляется из него
/// (`contrastBrand`). Применяется ко всем темам; вызывается при старте.
pub fn setColors(core: ?Rgb, brand: ?Rgb) void {
    for (&chosen, defaults) |*ch, d| {
        ch.* = d;
        if (core) |c| ch.core = c;
        if (d.brand) |db| {
            if (brand) |b| ch.brand = b else if (core) |c| ch.brand = contrastBrand(c, db);
        }
    }
    for (0..defaults.len) |bi| {
        const base: Base = @enumFromInt(bi);
        for ([_]bool{ false, true }) |dark| {
            const src = original(base, dark);
            const d = defaults[bi];
            const ch = chosen[bi];
            const l = &live[bi][@intFromBool(dark)];
            for (src.vars, 0..) |kv, i| {
                const c = parseColor(kv[1]) orelse {
                    l.kv[i] = kv;
                    continue;
                };
                const r = switch (role(base, kv[0])) {
                    .core => recolor(c, d.core, ch.core, dark),
                    .brand => if (d.brand) |db| recolor(c, db, ch.brand orelse db, dark) else c,
                    .fixed => c,
                };
                l.kv[i] = .{ kv[0], if (std.mem.eql(u8, &r, &c)) kv[1] else hexOf(&l.hex[i], r) };
            }
            l.pal = .{
                .vars = l.kv[0..src.vars.len],
                .g_header = recolorGrad(&l.grad[0], src.g_header, d.core, ch.core, dark),
                .g_tab = recolorGrad(&l.grad[1], src.g_tab, d.core, ch.core, dark),
                .g_footer = recolorGrad(&l.grad[2], src.g_footer, d.core, ch.core, dark),
            };
        }
    }
    live_ready = true;
}

/// Цвет, снятый со светлой палитры темы (например, в разметке встраиваемых
/// кусков), — пересчитанный от главного цвета так же, как палитра.
pub fn tint(buf: *[7]u8, base: Base, hex: []const u8) []const u8 {
    if (!live_ready) setColors(null, null);
    const c = parseColor(hex) orelse return hex;
    const i = @intFromEnum(base);
    const r = recolor(c, defaults[i].core, chosen[i].core, false);
    return if (std.mem.eql(u8, &r, &c)) hex else hexOf(buf, r);
}

/// Градиент для встраиваемых кусков — тоже от главного цвета.
pub fn tintGrad(out: []u8, base: Base, spec: []const u8) []const u8 {
    if (!live_ready) setColors(null, null);
    const i = @intFromEnum(base);
    return recolorGrad(out, spec, defaults[i].core, chosen[i].core, false);
}

fn original(base: Base, dark: bool) *const Pal {
    return switch (base) {
        .flibusta => if (dark) &flibusta_dark else &flibusta_light,
        .samlib => if (dark) &samlib_dark else &samlib_light,
        .proza => if (dark) &proza_dark else &proza_light,
        .nepomn => if (dark) &nepomn_dark else &nepomn_light,
    };
}

fn pal(base: Base, dark: bool) *const Pal {
    if (!live_ready) setColors(null, null);
    return &live[@intFromEnum(base)][@intFromBool(dark)].pal;
}

test "главный цвет: по умолчанию — исходная палитра, другой — пересчёт" {
    // главный цвет по умолчанию, заданный явно, не меняет ни одного цвета
    setColors(defaults[0].core, null);
    for (flibusta_light.vars, pal(.flibusta, false).vars) |a, b| try std.testing.expectEqualStrings(a[1], b[1]);
    try std.testing.expectEqualStrings(flibusta_light.g_header, pal(.flibusta, false).g_header);
    // сам главный цвет переходит ровно в заданный
    const red = parseColor("#c15252").?;
    setColors(red, parseColor("#123456"));
    var link: []const u8 = "";
    for (pal(.flibusta, false).vars) |kv| if (std.mem.eql(u8, kv[0], "link")) {
        link = kv[1];
    };
    try std.testing.expectEqualStrings("#c15252", link);
    // серое не трогается, белый фон остаётся почти белым
    try std.testing.expectEqualStrings("#393939", lightColor(.flibusta, "fg"));
    // фирменный цвет proza — логотип; у samlib смысловые цвета на месте
    var logo: []const u8 = "";
    for (pal(.proza, false).vars) |kv| if (std.mem.eql(u8, kv[0], "logo")) {
        logo = kv[1];
    };
    try std.testing.expectEqualStrings("#123456", logo);
    try std.testing.expectEqualStrings("#f1c9c9", lightColor(.samlib, "red"));
    // задан только главный: фирменный — контрастный ему (тон напротив)
    setColors(parseColor("#2050c0").?, null);
    for (pal(.proza, false).vars) |kv| if (std.mem.eql(u8, kv[0], "logo")) {
        logo = kv[1];
    };
    const lh = toHsl(parseColor(logo).?).h;
    try std.testing.expect(@abs(lh - @mod(toHsl(parseColor("#2050c0").?).h + 180, 360)) < 3);
    setColors(null, null);
    try std.testing.expectEqualStrings("#5294c1", lightColor(.flibusta, "link"));
}

/// «?v=…» к адресам стилей, значка и логотипа, когда они не встроенные (-c, -b,
/// -ico, -png): браузер держит их сутки, и без метки после перезапуска с
/// другими цветами показал бы прежние. Пусто — всё по умолчанию.
pub var asset_q: []const u8 = "";
var asset_q_buf: [16]u8 = undefined;

pub fn setAssetVersion(core: ?Rgb, brand: ?Rgb, ico: ?[]const u8, png: ?[]const u8) void {
    if (core == null and brand == null and ico == null and png == null) {
        asset_q = "";
        return;
    }
    var h = std.hash.Wyhash.init(7);
    if (core) |c| h.update(&c);
    h.update("|");
    if (brand) |b| h.update(&b);
    h.update("|");
    if (ico) |b| h.update(b);
    h.update("|");
    if (png) |b| h.update(b);
    asset_q = std.fmt.bufPrint(&asset_q_buf, "?v={x:0>8}", .{@as(u32, @truncate(h.final()))}) catch "";
}

/// Цвет светлой палитры: запасные атрибуты <body> для браузеров без CSS-переменных.
pub fn lightColor(base: Base, comptime name: []const u8) []const u8 {
    for (pal(base, false).vars) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
    return "#000000";
}

fn vars(w: *W, p: *const Pal) void {
    w.raw(":root{");
    for (p.vars) |kv| {
        w.raw("--");
        w.raw(kv[0]);
        w.byte(':');
        w.raw(kv[1]);
        w.byte(';');
    }
    w.byte('}');
}

fn grads(w: *W, p: *const Pal) void {
    if (p.g_header.len == 0) return;
    var head: []const u8 = "#e5ecf5";
    for (p.vars) |kv| if (std.mem.eql(u8, kv[0], "blockHead")) {
        head = kv[1];
    };
    w.f("#header{background:{s} url(/g/91/{s}.bmp) repeat-x}#primary a{background:url(/g/18/{s}.bmp) repeat-x}#footer{background:url(/g/37/{s}.bmp) repeat-x}", .{ head, p.g_header, p.g_tab, p.g_footer });
}

// Порядок как в макете: общие правила, тема, градиенты, меню отметок и мобильные правила.
const common_css = @embedFile("tpl/common.css");
const after_css = @embedFile("tpl/after.css");
const theme_css = [_][]const u8{ @embedFile("tpl/flibusta/main.css"), @embedFile("tpl/samlib/main.css"), @embedFile("tpl/proza/main.css"), @embedFile("tpl/nepomn/main.css") };

/// Таблица стилей темы в режиме auto (по устройству), light или dark.
pub fn css(w: *W, base: Base, mode: Mode) void {
    switch (mode) {
        .light => vars(w, pal(base, false)),
        .dark => vars(w, pal(base, true)),
        else => {
            vars(w, pal(base, false));
            w.raw("@media (prefers-color-scheme: dark){");
            vars(w, pal(base, true));
            w.byte('}');
        },
    }
    w.byte('\n');
    w.raw(common_css);
    w.raw(theme_css[@intFromEnum(base)]);
    switch (mode) {
        .light => grads(w, pal(base, false)),
        .dark => grads(w, pal(base, true)),
        else => {
            grads(w, pal(base, false));
            if (pal(base, true).g_header.len > 0) {
                w.raw("@media (prefers-color-scheme: dark){");
                grads(w, pal(base, true));
                w.byte('}');
            }
        },
    }
    w.byte('\n');
    w.raw(after_css);
}

/// Вертикальный градиент шириной 1 пиксель, 24-битный BMP.
/// `spec` — цвета `rrggbb` через дефис. null — неверный запрос.
pub fn gradientBmp(a: std.mem.Allocator, spec: []const u8, h: u32) ?[]u8 {
    var stops: [16][3]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, '-');
    while (it.next()) |s| {
        if (s.len != 6) continue;
        var c: [3]u8 = undefined;
        _ = std.fmt.hexToBytes(&c, s) catch continue;
        if (n == stops.len) return null;
        stops[n] = c;
        n += 1;
    }
    if (n < 1 or h == 0 or h > 400) return null;
    const row = 4; // 1 пиксель × 3 байта, выровнено до 4
    const size = 54 + row * h;
    const b = a.alloc(u8, size) catch return null;
    @memset(b, 0);
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(u32, b[2..6], size, .little);
    std.mem.writeInt(u32, b[10..14], 54, .little);
    std.mem.writeInt(u32, b[14..18], 40, .little);
    std.mem.writeInt(i32, b[18..22], 1, .little);
    std.mem.writeInt(i32, b[22..26], @intCast(h), .little);
    std.mem.writeInt(u16, b[26..28], 1, .little);
    std.mem.writeInt(u16, b[28..30], 24, .little);
    std.mem.writeInt(u32, b[34..38], row * h, .little);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        // позиция в градиенте в 1/1024 долях отрезка
        const t: u64 = if (h == 1 or n == 1) 0 else @as(u64, y) * (n - 1) * 1024 / (h - 1);
        const i: usize = @min(@as(usize, @intCast(t / 1024)), if (n >= 2) n - 2 else 0);
        const f: u64 = t - i * 1024;
        const lo = stops[i];
        const hi = stops[@min(i + 1, n - 1)];
        const o = 54 + (h - 1 - y) * row; // снизу вверх
        inline for (.{ 2, 1, 0 }, 0..) |ch, k| {
            const x: i64 = lo[ch];
            const z: i64 = hi[ch];
            b[o + k] = @intCast(x + @divTrunc((z - x) * @as(i64, @intCast(f)) + 512, 1024));
        }
    }
    return b;
}

test "тема по настройкам панели" {
    const all = Look{ .base = .flibusta };
    try std.testing.expectEqual(Theme{ .base = .samlib, .mode = .dark }, pick("samlib-dark", all));
    try std.testing.expectEqual(Theme{ .base = .flibusta, .mode = .time }, pick("time", all));
    try std.testing.expectEqual(Theme{ .base = .flibusta, .mode = .auto }, pick("nonsense-x", all));
    // по умолчанию тёмная proza; посетителю оставлены samlib и светлый режим
    const some = Look{ .base = .proza, .mode = .dark, .bases = 0b0010, .modes = 0b0010 };
    try std.testing.expectEqual(Theme{ .base = .proza, .mode = .dark }, pick("", some));
    try std.testing.expectEqual(Theme{ .base = .samlib, .mode = .light }, pick("samlib-light", some));
    try std.testing.expectEqual(Theme{ .base = .proza, .mode = .dark }, pick("nepomn-time", some));
    try std.testing.expectEqual(Theme{ .base = .samlib, .mode = .dark }, pick("samlib-auto", some));
    // настройка скрыта: `t` ничего не меняет
    var hidden = some;
    hidden.show = false;
    try std.testing.expectEqual(Theme{ .base = .proza, .mode = .dark }, pick("samlib-light", hidden));
}

test "разбор темы" {
    try std.testing.expectEqual(Theme{ .base = .samlib, .mode = .dark }, parse("samlib-dark", .flibusta));
    try std.testing.expectEqual(Theme{ .base = .proza, .mode = .time }, parse("time", .proza));
    try std.testing.expectEqual(Theme{ .base = .flibusta, .mode = .auto }, parse("nonsense-x", .flibusta));
    try std.testing.expectEqual(Theme{ .base = .nepomn, .mode = .auto }, parse(null, .nepomn));
    try std.testing.expectEqual(Mode.dark, resolve(.time, 23));
    try std.testing.expectEqual(Mode.light, resolve(.time, 12));
}

test "градиент и стили" {
    const a = std.testing.allocator;
    const bmp = gradientBmp(a, "000000-ffffff", 3).?;
    defer a.free(bmp);
    try std.testing.expectEqual(@as(usize, 54 + 12), bmp.len);
    try std.testing.expectEqual(@as(u8, 0xff), bmp[54]); // нижняя строка — последний цвет
    try std.testing.expectEqual(@as(u8, 0), bmp[54 + 8]);
    try std.testing.expect(gradientBmp(a, "zz", 3) == null);
    try std.testing.expect(gradientBmp(a, "000000", 401) == null);
    var buf: [16000]u8 = undefined;
    var w = W.init(&buf);
    css(&w, .flibusta, .auto);
    try std.testing.expect(!w.over);
    try std.testing.expect(std.mem.indexOf(u8, w.out(), "prefers-color-scheme") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.out(), "/g/91/83a5c9-") != null);
}
