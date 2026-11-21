//! Шаблоны: файл из `src/tpl/` встраивается в бинарник (`@embedFile`), при
//! компиляции режется по `{{имя}}` и перекодируется в windows-1251. При
//! запросе остаётся цепочка «записать кусок — вызвать метод».
//!
//!   {{имя}}     вызов `ctx.имя(w)`; неизвестное имя — ошибка компиляции
//!   {{/путь}}   адрес сайта с протягиваемыми `m` и `t`

const std = @import("std");
const cp = @import("cp1251.zig");
const W = @import("out.zig").W;

pub fn render(comptime src: []const u8, w: *W, ctx: anytype) void {
    @setEvalBranchQuota(src.len * 200 + 20000);
    comptime var rest: []const u8 = src;
    inline while (true) {
        const open = comptime std.mem.indexOf(u8, rest, "{{") orelse break;
        const close = comptime std.mem.indexOfPos(u8, rest, open, "}}") orelse @compileError("шаблон: не закрыто {{");
        if (open > 0) w.raw(comptime cp.lit(rest[0..open]));
        const name = comptime rest[open + 2 .. close];
        if (comptime name[0] == '/') {
            w.link(name);
        } else {
            @field(@TypeOf(ctx.*), name)(ctx, w);
        }
        rest = comptime rest[close + 2 ..];
    }
    if (rest.len > 0) w.raw(comptime cp.lit(rest));
}

test "шаблон" {
    const Ctx = struct {
        n: u8,
        pub fn title(c: *@This(), w: *W) void {
            w.int(c.n);
        }
    };
    var buf: [128]u8 = undefined;
    var w = W.init(&buf);
    w.tm = "m=true";
    var c = Ctx{ .n = 7 };
    render("<a href=\"{{/help}}\">{{title}}</a> —", &w, &c);
    try std.testing.expectEqualStrings("<a href=\"/help?m=true\">7</a> \x97", w.out());
}
