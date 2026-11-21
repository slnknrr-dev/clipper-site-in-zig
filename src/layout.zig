//! Оформление страницы по темам. Каждая тема повторяет устройство настоящего
//! сайта (flibusta.is, samlib.ru, proza.ru, nepomn.ru) средствами HTML 4.01
//! и CSS времён 2003 года: таблицы, атрибуты цвета, фоновые полоски.
//! Разметка тем — шаблоны `src/tpl/`, здесь — содержимое их вставок.

const std = @import("std");
const cp = @import("cp1251.zig");
const tpl = @import("tpl.zig");
const theme = @import("theme.zig");
const sys = @import("sys.zig");
const dbm = @import("db.zig");
const W = @import("out.zig").W;
const app_mod = @import("app.zig");
const Ctx = app_mod.Ctx;
const PageOpts = app_mod.PageOpts;

pub const Section = struct { href: []const u8, title: []const u8, hint: []const u8 };
pub const sections = [_]Section{
    .{ .href = "/p", .title = cp.lit("Стихи"), .hint = cp.lit("стихи, верлибры, песни") },
    .{ .href = "/b", .title = cp.lit("Книги"), .hint = cp.lit("книги и серии") },
    .{ .href = "/c", .title = cp.lit("Цитаты"), .hint = cp.lit("люди и персонажи") },
    .{ .href = "/d", .title = cp.lit("Черновики"), .hint = cp.lit("черновики и статьи") },
    .{ .href = "/f", .title = cp.lit("Форумы"), .hint = cp.lit("форумы и имиджборды") },
} ++ (if (@import("config").voice) [_]Section{
    .{ .href = "/v", .title = cp.lit("Записи"), .hint = cp.lit("аудиокниги, чтецы и исполнители") },
} else [_]Section{}) ++ [_]Section{
    .{ .href = "/u", .title = cp.lit("Авторы"), .hint = cp.lit("пользователи и авторы") },
};

/// Виден ли раздел (переключатели функций; администратор видит всё).
pub fn sectionOn(c: *const Ctx, href: []const u8) bool {
    if (href.len < 2) return true;
    return switch (href[1]) {
        'f' => c.featureOpen(.forum) or c.featureOpen(.boards),
        'p' => c.featureOpen(.poems),
        'b', 'q' => c.featureOpen(.books),
        'c' => c.featureOpen(.quotes),
        'd' => c.featureOpen(.drafts),
        'v' => c.secListed(.v),
        else => true,
    };
}

/// Адрес с заменёнными `t` и/или `m` (null — не трогать, "" — убрать).
pub fn withParams(w: *W, url: []const u8, t: ?[]const u8, m: ?[]const u8) void {
    const qm = std.mem.indexOfScalar(u8, url, '?');
    const path = if (qm) |i| url[0..i] else url;
    w.esc(path);
    var first = true;
    const Sep = struct {
        fn put(ww: *W, f: *bool) void {
            ww.raw(if (f.*) "?" else "&amp;");
            f.* = false;
        }
    };
    if (qm) |i| {
        var it = std.mem.splitScalar(u8, url[i + 1 ..], '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (t != null and std.mem.startsWith(u8, pair, "t=")) continue;
            if (m != null and std.mem.startsWith(u8, pair, "m=")) continue;
            Sep.put(w, &first);
            w.esc(pair);
        }
    }
    if (t) |v| if (v.len > 0) {
        Sep.put(w, &first);
        w.raw("t=");
        w.urlenc(v);
    };
    if (m) |v| if (v.len > 0) {
        Sep.put(w, &first);
        w.raw("m=");
        w.urlenc(v);
    };
}

const Parts = struct {
    c: *Ctx,
    o: PageOpts,
    side_w: []const u8 = "270",

    fn item(p: *Parts, w: *W, s: Section, extra_class: []const u8) void {
        const active = std.mem.eql(u8, p.o.sec, s.href);
        w.raw("<a ");
        if (extra_class.len > 0) w.raw(extra_class);
        w.f("href=\"{U}{s}{E}\" title=\"{s}\"", .{ s.href, s.hint });
        if (active and extra_class.len == 0) w.raw(" class=\"active\"");
        w.f(">{s}</a>", .{s.title});
    }

    /// Мобильная версия сайта из одного раздела: меню разделов нет, остаются поиск и вход.
    fn noMenu(p: *Parts) bool {
        return p.c.mobile and @popCount(@import("pages/home.zig").listed(p.c)) <= 1;
    }

    pub fn menu(p: *Parts, w: *W) void {
        if (p.noMenu()) return;
        for (sections) |s| if (sectionOn(p.c, s.href)) p.item(w, s, "");
    }
    pub fn menu_li(p: *Parts, w: *W) void {
        if (p.noMenu()) return;
        for (sections) |s| if (sectionOn(p.c, s.href)) {
            w.raw("<li>&raquo; ");
            p.item(w, s, "");
            w.raw("</li>");
        };
    }
    pub fn menu_br(p: *Parts, w: *W) void {
        if (p.noMenu()) return;
        var first = true;
        for (sections) |s| if (sectionOn(p.c, s.href)) {
            if (!first) w.raw("<br>");
            first = false;
            p.item(w, s, "");
        };
    }
    pub fn menu_sq(p: *Parts, w: *W) void {
        if (p.noMenu()) return;
        var first = true;
        for (sections) |s| if (sectionOn(p.c, s.href)) {
            if (!first) w.byte(' ');
            first = false;
            w.byte('[');
            p.item(w, s, "");
            w.byte(']');
        };
    }
    pub fn menu_nepomn(p: *Parts, w: *W) void {
        if (p.noMenu()) return;
        for (sections) |s| if (sectionOn(p.c, s.href)) {
            w.raw("<li class=\"menu\">");
            p.item(w, s, "class=\"menu\" ");
            w.raw("</li>");
        };
    }

    /// Колонка рубрик proza: у песенника — жанры, у цитатника — люди и персонажи,
    /// у прочих — разделы сайта, как у proza.ru слева.
    pub fn rubrics_proza(p: *Parts, w: *W) void {
        const home = @import("pages/home.zig");
        const s = p.c.db.s;
        switch (home.archetype(home.listed(p.c))) {
            .songbook => {
                var seen: [32][]const u8 = undefined;
                var n: usize = 0;
                for (0..s.pieces.len) |i| {
                    const g = s.str(s.pieceAt(i).genre);
                    if (g.len == 0) continue;
                    var dup = false;
                    for (seen[0..n]) |x| dup = dup or cp.eqlFold(x, g);
                    if (dup or n == seen.len) continue;
                    seen[n] = g;
                    n += 1;
                    if (n > 1) w.raw("<br>");
                    w.f("<a href=\"{U}/p?g={q}{E}\">{h}</a>", .{ g, g });
                }
            },
            .quotes => w.f("<a href=\"{U}/c{E}\">Люди</a><br><a href=\"{U}/c#chars{E}\">Персонажи</a>", .{}),
            else => p.menu_br(w),
        }
    }

    // Тексты шапок из видимых разделов (home.zig): выключенное не называется.
    pub fn slogan(p: *Parts, w: *W) void {
        @import("pages/home.zig").slogan(w, @import("pages/home.zig").listed(p.c));
    }
    pub fn search_title(p: *Parts, w: *W) void {
        if (p.c.secListed(.b)) w.s("Поиск книг") else w.s("Поиск");
    }
    pub fn kind_upper(p: *Parts, w: *W) void {
        const n = @import("pages/home.zig").kindNoun(@import("pages/home.zig").listed(p.c));
        for (n) |ch| w.byte(cp.upper(ch));
    }
    pub fn kind_lower(p: *Parts, w: *W) void {
        const home = @import("pages/home.zig");
        const set = home.listed(p.c);
        if (set == 0b11111) return w.s("цифровая библиотека");
        w.raw(home.kindNoun(set));
    }
    pub fn proza_lead(p: *Parts, w: *W) void {
        const home = @import("pages/home.zig");
        const set = home.listed(p.c);
        if (set == 0b11111) w.s("цифровая библиотека") else w.raw(home.kindNoun(set));
        w.raw(" ");
        home.listGenitive(w, set);
    }
    pub fn samlib_title(p: *Parts, w: *W) void {
        @import("pages/home.zig").samlibTitle(w, @import("pages/home.zig").listed(p.c));
    }

    pub fn crumbs(p: *Parts, w: *W) void {
        if (p.o.crumbs.len == 0) {
            w.f("<b>{h}</b>", .{p.c.app.name});
            return;
        }
        w.f("<a href=\"{U}/{E}\">{h}</a>", .{p.c.app.name});
        for (p.o.crumbs, 0..) |cr, i| {
            w.raw(" &raquo; ");
            if (cr.href.len > 0 and i + 1 < p.o.crumbs.len) {
                w.f("<a href=\"{U}{h}{E}\">{h}</a>", .{ cr.href, cr.text });
            } else w.f("<b>{h}</b>", .{cr.text});
        }
    }

    pub fn search(p: *Parts, w: *W) void {
        const c = p.c;
        w.raw("<form action=\"/s\" method=\"get\" style=\"margin:0\">");
        hiddenTo(c, w);
        w.f("<input name=\"q\" size=\"16\" value=\"{h}\"> <input type=\"submit\" value=\"Найти\"></form>", .{if (c.seg.len == 1 and std.mem.eql(u8, c.seg[0], "s")) c.q("q") else ""});
    }

    // Блок «Оформление» в колонке: скрыт целиком, если так решено в панели.
    pub fn themes_flibusta(p: *Parts, w: *W) void {
        if (!p.c.app.look.show) return;
        w.s("<div class=\"block\"><h2>Оформление</h2><div class=\"content\">");
        p.themes(w);
        w.raw("</div></div>");
    }
    pub fn themes_samlib(p: *Parts, w: *W) void {
        if (!p.c.app.look.show) return;
        w.s("<table width=\"100%\" class=\"c2\" cellpadding=\"3\"><tr><td><b>ОФОРМЛЕНИЕ:</b></td></tr></table><div class=\"small\" style=\"margin:3px 0 10px\">");
        p.themes(w);
        w.raw("</div>");
    }
    pub fn themes_proza(p: *Parts, w: *W) void {
        if (!p.c.app.look.show) return;
        w.s("<h5 class=\"columntitle\">Оформление</h5><span style=\"font-size:14px\">");
        p.themes(w);
        w.raw("</span>");
    }
    pub fn themes_nepomn(p: *Parts, w: *W) void {
        if (!p.c.app.look.show) return;
        w.s("<div class=\"leftx\"><b>Оформление:</b><br>");
        p.themes(w);
        w.raw("</div>");
    }

    fn themes(p: *Parts, w: *W) void {
        const c = p.c;
        w.raw(@tagName(c.th.base));
        if (c.th.mode != .auto) {
            w.byte('-');
            w.raw(@tagName(c.th.mode));
        }
        w.raw("<br><a href=\"/theme?url=");
        w.urlenc(c.here());
        if (c.t_raw.len > 0) {
            w.raw("&amp;t=");
            w.urlenc(c.t_raw);
        }
        if (c.m_raw.len > 0) {
            w.raw("&amp;m=");
            w.urlenc(c.m_raw);
        }
        w.s("\">Настроить оформление&hellip;</a>");
    }

    pub fn mob(p: *Parts, w: *W) void {
        const c = p.c;
        w.raw("<a href=\"");
        withParams(w, c.here(), null, if (c.mobile) "false" else "true");
        w.raw("\">");
        if (c.mobile) w.s("Полная версия") else w.s("Мобильная версия");
        w.raw("</a>");
    }

    pub fn help(_: *Parts, w: *W) void {
        w.f("<a href=\"{U}/help{E}\">Схема адресов</a>", .{});
    }

    pub fn auth(p: *Parts, w: *W) void {
        const c = p.c;
        const me = c.me orelse {
            w.f("<a href=\"{U}/signin?back={q}{E}\">Войти</a> · ", .{c.here()});
            if (c.featureOn(.signup)) w.f("<a href=\"{U}/signup{E}\">Регистрация</a>", .{});
            if (c.app.fed.on()) w.f("<br><a href=\"{U}/fed{E}\">Вход с другого сайта</a>", .{});
            return;
        };
        w.f("<a href=\"{U}/u/{d}{E}\"><b>{h}</b></a><br>\n", .{ me.user, c.db.name(me.user) });
        if (c.secListed(.b)) w.f("<a href=\"{U}/bookmarks{E}\">Закладки</a> · ", .{});
        w.f("<a href=\"{U}/panel{E}\">Панель</a> · <a href=\"{U}/logout{E}\">Выйти</a>", .{});
        if (c.can(dbm.rights.upload, .upload)) w.f("<br><a href=\"{U}/b/upload{E}\">Выложить книгу</a>", .{});
        if (c.app.fed.on()) w.f("<br><a href=\"{U}/fed{E}\">Другие сайты (федерация)</a>", .{});
    }

    pub fn body(p: *Parts, w: *W) void {
        w.embed(&p.c.w);
    }

    pub fn title(p: *Parts, w: *W) void {
        w.esc(p.o.title);
    }

    /// Название сайта (-n).
    pub fn name(p: *Parts, w: *W) void {
        w.esc(p.c.app.name);
    }
    /// Адрес сайта (-s): целиком и двумя частями для логотипа — до первой точки и от неё.
    pub fn site(p: *Parts, w: *W) void {
        w.esc(p.c.app.site);
    }
    pub fn site_a(p: *Parts, w: *W) void {
        const s = p.c.app.site;
        w.esc(s[0 .. std.mem.indexOfScalar(u8, s, '.') orelse s.len]);
    }
    pub fn site_b(p: *Parts, w: *W) void {
        const s = p.c.app.site;
        w.esc(s[std.mem.indexOfScalar(u8, s, '.') orelse s.len ..]);
    }

    pub fn letters(p: *Parts, w: *W) void {
        if (!p.c.secListed(.p) and !p.c.secListed(.b) and !p.c.secListed(.q)) return;
        const abc = comptime cp.text("АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЭЮЯ");
        for (abc, 0..) |ch, i| {
            if (i > 0) w.byte(' ');
            w.f("[<a href=\"{U}/s?q={q}{E}\">{s}</a>]", .{ &[1]u8{ch}, &[1]u8{ch} });
        }
    }

    // Две колонки таблицей — или блоки друг под другом в мобильной версии.
    pub fn cols_a(p: *Parts, w: *W) void {
        if (p.c.mobile) {
            w.f("<div class=\"mtop\"><a href=\"#menu\">&#9776; Меню</a> <a href=\"{U}/{E}\">Главная</a> <a href=\"{U}/s{E}\">Поиск</a></div><div class=\"main\">", .{});
        } else w.raw("<table class=\"frame\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\"><tr><td class=\"main\" valign=\"top\">");
    }
    pub fn cols_b(p: *Parts, w: *W) void {
        if (p.c.mobile) {
            w.raw("</div><a name=\"menu\"></a><div class=\"side side-stack\">");
        } else w.f("</td><td class=\"side\" width=\"{s}\" valign=\"top\">", .{p.side_w});
    }
    pub fn cols_c(p: *Parts, w: *W) void {
        if (p.c.mobile) w.s("<p class=\"mtop\"><a href=\"#top\">&uarr; Наверх</a></p></div>") else w.raw("</td></tr></table>");
    }

    pub fn extra_flibusta(p: *Parts, w: *W) void {
        if (p.o.side.len == 0) return;
        w.f("<div class=\"block\"><h2>Навигация по тексту</h2><div class=\"content\"><h4>{s}</h4>{s}</div></div>", .{ p.o.side_head, p.o.side });
    }
    pub fn extra_samlib(p: *Parts, w: *W) void {
        if (p.o.side.len == 0) return;
        w.f("<table width=\"100%\" class=\"c3\" cellpadding=\"3\"><tr><td><b>ОГЛАВЛЕНИЕ:</b></td></tr></table><div class=\"small\" style=\"margin:3px 0 10px\"><h4>{s}</h4>{s}</div>", .{ p.o.side_head, p.o.side });
    }
    pub fn extra_proza(p: *Parts, w: *W) void {
        if (p.o.side.len == 0) return;
        w.f("<h5 class=\"columntitle\">Оглавление</h5>{s}", .{p.o.side});
    }
    pub fn extra_nepomn(p: *Parts, w: *W) void {
        if (p.o.side.len == 0) return;
        w.f("<div class=\"leftx\"><b>Главы:</b><br>{s}</div>", .{p.o.side});
    }

    pub fn nepomn_top(p: *Parts, w: *W) void {
        tpl.render(@embedFile("tpl/nepomn/top.html"), w, p);
    }
    pub fn nepomn_left(p: *Parts, w: *W) void {
        tpl.render(@embedFile("tpl/nepomn/left.html"), w, p);
    }

    pub fn html_class(p: *Parts, w: *W) void {
        if (p.c.mobile) w.raw(" class=\"mob\"");
    }
    pub fn css_href(p: *Parts, w: *W) void {
        w.f("/css/{s}-{s}.css{s}", .{ @tagName(p.c.th.base), @tagName(p.c.th.mode), theme.asset_q });
    }
    pub fn asset_q(_: *Parts, w: *W) void {
        w.raw(theme.asset_q);
    }
    pub fn body_attrs(p: *Parts, w: *W) void {
        const b = p.c.th.base;
        w.f(" bgcolor=\"{s}\" text=\"{s}\" link=\"{s}\" vlink=\"{s}\" class=\"{s}{s}\"", .{
            theme.lightColor(b, "bg"), theme.lightColor(b, "fg"), theme.lightColor(b, "link"), theme.lightColor(b, "vlink"), @tagName(b), if (p.c.mobile) " mob" else "",
        });
    }
    pub fn layout(p: *Parts, w: *W) void {
        switch (p.c.th.base) {
            .flibusta => {
                p.side_w = "270";
                tpl.render(@embedFile("tpl/flibusta/full.html"), w, p);
            },
            .samlib => {
                p.side_w = "33%";
                tpl.render(@embedFile("tpl/samlib/full.html"), w, p);
            },
            .proza => {
                p.side_w = "300";
                tpl.render(@embedFile("tpl/proza/full.html"), w, p);
            },
            .nepomn => if (p.c.mobile) tpl.render(@embedFile("tpl/nepomn/mobile.html"), w, p) else tpl.render(@embedFile("tpl/nepomn/full.html"), w, p),
        }
    }
};

pub fn hiddenTo(c: *Ctx, w: *W) void {
    if (c.m_raw.len > 0) w.f("<input type=\"hidden\" name=\"m\" value=\"{h}\">", .{c.m_raw});
    if (c.t_raw.len > 0) w.f("<input type=\"hidden\" name=\"t\" value=\"{h}\">", .{c.t_raw});
}

/// Собирает страницу: тело из `c.w` в оформлении темы — в `c.out`.
pub fn page(c: *Ctx, o: PageOpts) void {
    var p = Parts{ .c = c, .o = o };
    c.out.n = 0;
    c.out.csrf_n = 0;
    c.out.csrf_many = false;
    tpl.render(@embedFile("tpl/page.html"), &c.out, &p);
}

// ───────────── /theme ─────────────

fn themeBack(u: []const u8) []const u8 {
    if (u.len > 0 and u[0] == '/' and !std.mem.startsWith(u8, u, "//") and !std.mem.startsWith(u8, u, "/\\") and !std.mem.startsWith(u8, u, "/theme")) return u;
    return "/";
}

const theme_css =
    \\body{margin:0;background:#808080;color:#000;font:12px Tahoma,Verdana,Arial,sans-serif}
    \\.bar{background:#404040;color:#e0e0e0;padding:4px 10px;font-weight:bold}.bar a{color:#fff}
    \\td.pv,div.pv{padding:10px}
    \\.cap{background:#c0c0c0;border:2px outset #e0e0e0;border-bottom:0;padding:3px 6px;font-size:11px}
    \\iframe{border:2px inset #c0c0c0;background:#fff;display:block}
    \\td.ctl,div.ctl{background:#c0c0c0;border-left:2px outset #e0e0e0;border-right:2px outset #e0e0e0;padding:10px}
    \\h1{font-size:16px;margin:0 0 8px;color:#202020}
    \\.grp{margin:10px 0 3px;font-weight:bold;color:#404040;border-bottom:1px solid #808080}
    \\a.btn{display:block;margin:2px 0;padding:3px 6px;background:#d4d0c8;border:2px outset #fff;color:#000;text-decoration:none}
    \\a.btn:active,a.btn.on{border:2px inset #fff;background:#a8a8a8;font-weight:bold}
    \\a.btn small{font-weight:normal;color:#404040}
    \\a.ret{margin-top:12px;background:#e8e8d0;font-weight:bold}
    \\.res{padding:3px 0}
    \\.note{font-size:10px;color:#404040;word-wrap:break-word}
;

/// /theme?url=/назад&t=… — отдельная серая страница настроек с живым
/// предпросмотром светлой и тёмной палитр (iframe, HTML 4.0).
pub fn themePage(c: *Ctx) void {
    const w = &c.out;
    const look = c.app.look;
    if (!look.show) return c.notFound();
    const back = themeBack(c.q("url"));
    const base = c.th.base;
    const mode = c.th.mode;
    const now_mode = theme.resolve(mode, sys.localHour());

    const H = struct {
        fn selfHref(cc: *Ctx, ww: *W, bk: []const u8, b: ?theme.Base, m: theme.Mode) void {
            ww.raw("/theme?url=");
            ww.urlenc(bk);
            ww.raw("&amp;t=");
            if (b) |bb| theme.value(ww, bb, m, cc.app.look);
            if (cc.m_raw.len > 0) {
                ww.raw("&amp;m=");
                ww.urlenc(cc.m_raw);
            }
        }
        fn preview(cc: *Ctx, ww: *W, bk: []const u8, b: theme.Base, dark: bool, cur: bool) void {
            ww.raw("<div class=\"cap\">");
            if (dark) ww.s("Тёмная") else ww.s("Светлая");
            ww.f(": {s}-{s}", .{ @tagName(b), if (dark) "dark" else "light" });
            if (cur) ww.s(" &mdash; <b>сейчас</b>");
            ww.raw("</div>\n<iframe src=\"");
            const t = std.fmt.allocPrint(cc.a, "{s}-{s}", .{ @tagName(b), if (dark) "dark" else "light" }) catch "";
            withParams(ww, bk, t, "true");
            ww.f("\" width=\"100%\" height=\"{d}\" frameborder=\"0\" scrolling=\"auto\" title=\"{s}\"></iframe>", .{ @as(i64, if (cc.mobile) 360 else 520), if (dark) "dark" else "light" });
        }
    };

    w.s("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">\n<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>Оформление :: ");
    w.esc(c.app.name);
    w.s("</title><link rel=\"shortcut icon\" href=\"/favicon.ico");
    w.raw(theme.asset_q);
    w.s("\" type=\"image/x-icon\">\n<style type=\"text/css\">\n");
    w.raw(theme_css);
    w.raw("\n</style></head><body>\n<div class=\"bar\"><a href=\"");
    const chosen: ?[]const u8 = if (c.t_raw.len > 0) (if (mode == look.mode) @tagName(base) else std.fmt.allocPrint(c.a, "{s}-{s}", .{ @tagName(base), @tagName(mode) }) catch "") else null;
    withParams(w, back, chosen orelse "", null);
    w.f("\">{h}</a> &raquo; настройка оформления</div>\n", .{c.app.name});

    if (c.mobile) w.raw("<div class=\"ctl\">") else {
        w.raw("<table width=\"100%\" cellspacing=\"0\" cellpadding=\"0\"><tr valign=\"top\"><td class=\"pv\">");
        H.preview(c, w, back, base, false, now_mode == .light);
        w.raw("</td><td class=\"ctl\" width=\"230\">");
    }
    // управление
    w.s("<h1>Оформление</h1>\n<div class=\"grp\">Тема</div>");
    inline for (@typeInfo(theme.Base).@"enum".fields) |f| {
        const b: theme.Base = @field(theme.Base, f.name);
        if (look.baseOn(b)) {
        w.raw(if (b == base) "<a class=\"btn on\" href=\"" else "<a class=\"btn\" href=\"");
        H.selfHref(c, w, back, b, mode);
        w.raw("\">");
        if (b == base) w.raw("&#9679; ");
        w.raw(f.name);
        w.raw("</a>");
        }
    }
    w.s("\n<div class=\"grp\">Режим</div>");
    const modes = [_]struct { theme.Mode, []const u8 }{
        .{ .auto, cp.lit("как на устройстве") }, .{ .light, cp.lit("светлая") }, .{ .dark, cp.lit("тёмная") }, .{ .time, cp.lit("по времени суток") },
    };
    for (modes) |m| {
        if (!look.modeOn(m[0])) continue;
        w.raw(if (m[0] == mode) "<a class=\"btn on\" href=\"" else "<a class=\"btn\" href=\"");
        H.selfHref(c, w, back, base, m[0]);
        w.raw("\">");
        if (m[0] == mode) w.raw("&#9679; ");
        w.f("{s} <small>{s}</small></a>", .{ @tagName(m[0]), m[1] });
    }
    w.s("\n<div class=\"grp\">Итог</div><div class=\"res\">t=<b>");
    if (chosen) |ch| w.esc(ch) else w.s("(по умолчанию)");
    w.raw("</b></div>\n<a class=\"btn ret\" href=\"");
    withParams(w, back, chosen orelse "", null);
    w.s("\">&laquo; Применить и вернуться</a>\n<a class=\"btn\" href=\"");
    H.selfHref(c, w, back, null, .auto);
    w.s("\">Сбросить к умолчанию</a>\n<a class=\"btn\" href=\"");
    w.esc(back);
    w.s("\">Отмена</a>\n<p class=\"note\">Возврат на:<br><code>");
    w.esc(back);
    w.raw("</code></p>");

    if (c.mobile) {
        w.raw("</div><div class=\"pv\">");
        H.preview(c, w, back, base, false, now_mode == .light);
        w.raw("</div><div class=\"pv\">");
        H.preview(c, w, back, base, true, now_mode == .dark);
        w.raw("</div>");
    } else {
        w.raw("</td><td class=\"pv\">");
        H.preview(c, w, back, base, true, now_mode == .dark);
        w.raw("</td></tr></table>");
    }
    w.raw("\n</body></html>");
    c.send(app_mod.html_type, w.out());
}
