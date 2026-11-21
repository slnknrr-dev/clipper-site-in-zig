//! Инструмент сборки (цели Windows XP): копия PE-файла, в заголовке которой
//! запрошена Windows 5.1. Компоновщик всегда пишет 6.0, а XP отказывается
//! запускать программу с версией подсистемы выше своей.
//!
//!   pe-version <in.exe> <out.exe>

const std = @import("std");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 3) return error.Usage;
    const bytes = try std.fs.cwd().readFileAlloc(gpa, args[1], 256 << 20);
    defer gpa.free(bytes);
    const pe = std.mem.readInt(u32, bytes[0x3c..][0..4], .little);
    if (!std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const opt = pe + 24;
    // MajorOperatingSystemVersion, Minor…, затем MajorSubsystemVersion, Minor…
    for ([_]usize{ 40, 48 }) |at| {
        std.mem.writeInt(u16, bytes[opt + at ..][0..2], 5, .little);
        std.mem.writeInt(u16, bytes[opt + at + 2 ..][0..2], 1, .little);
    }
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = bytes });
}
