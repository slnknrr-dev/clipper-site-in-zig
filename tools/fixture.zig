//! zig build fixture -- ПАПКА [-btree]
//!
//! Кладёт в пустую папку библиотеки тестовую заготовку (test/fixture.zig):
//! людей, стихи и песни, участников, черновики, форумы и доски. Так готовят
//! сервер для node-тестов — сравнения с макетом, враждебного ввода, федерации,
//! воркеров. Сайт без заготовки начинается пустым: в программе этих данных нет.

const std = @import("std");
const fixture = @import("fixture");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(gpa);
    if (argv.len < 2) {
        std.debug.print("zig build fixture -- ПАПКА [-btree]\n", .{});
        std.process.exit(2);
    }
    const btree = argv.len > 2 and std.mem.eql(u8, argv[2], "-btree");
    var dir = try std.fs.cwd().makeOpenPath(argv[1], .{});
    defer dir.close();
    dir.access("library.current", .{}) catch {
        try fixture.prepare(gpa, argv[1], btree);
        std.debug.print("fixture: заготовка записана в {s}\n", .{argv[1]});
        return;
    };
    std.debug.print("fixture: в {s} уже есть библиотека — заготовка кладётся только в новую папку\n", .{argv[1]});
    std.process.exit(1);
}
