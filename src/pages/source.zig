//! Источник произведения: откуда оно (книга, стих, запись, статья) — адрес или
//! название: mrakopedia, arxiv, habr и т. п. Хранится ключом O<вид><номер>
//! (db.source); вид — b, p, v, d.

const std = @import("std");
const Ctx = @import("../app.zig").Ctx;

pub const max_len = 300;

fn isUrl(v: []const u8) bool {
    return std.mem.startsWith(u8, v, "http://") or std.mem.startsWith(u8, v, "https://");
}

/// Короткое имя сайта для ссылки: «https://www.habr.com/ru/…» → «habr.com».
fn host(v: []const u8) []const u8 {
    var s = v[(std.mem.indexOf(u8, v, "://") orelse return v) + 3 ..];
    if (std.mem.indexOfAny(u8, s, "/?#")) |e| s = s[0..e];
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    return if (s.len > 0) s else v;
}

/// Строка «Источник: …» под заголовком; нет источника — ничего.
pub fn show(c: *Ctx, kind: u8, id: i32) void {
    const v = c.db.source(kind, id);
    if (v.len == 0) return;
    const w = &c.w;
    w.s("<div class=\"muted\">Источник: ");
    if (isUrl(v)) w.f("<a href=\"{h}\" rel=\"nofollow noopener\">{h}</a>", .{ v, host(v) }) else w.esc(v);
    w.raw("</div>\n");
}

/// Строка формы с полем источника.
pub fn row(c: *Ctx, cur: []const u8) void {
    c.w.f("<tr><td>Источник</td><td><input name=\"source\" size=\"40\" value=\"{h}\"><br>", .{cur});
    c.w.s("<span class=\"muted\">Необязательно: откуда произведение — адрес или название (mrakopedia, arxiv, habr…).</span></td></tr>\n");
}

/// Источник из формы: одна строка, не длиннее max_len.
pub fn fromForm(c: *Ctx) []const u8 {
    const v = std.mem.trim(u8, c.form.get("source"), " \r\n\t");
    const out = c.a.dupe(u8, v[0..@min(v.len, max_len)]) catch return "";
    for (out) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

/// Сохраняет источник из формы (поле есть в форме — пустое значение стирает).
pub fn save(c: *Ctx, kind: u8, id: i32) void {
    c.db.setSource(kind, id, fromForm(c));
}
