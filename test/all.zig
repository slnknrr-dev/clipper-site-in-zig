//! zig build test: модульные тесты всех модулей и сквозные проверки.
const clipper = @import("clipper");

test {
    _ = clipper;
    @import("std").testing.refAllDecls(clipper);
    _ = @import("hostile.zig");
    _ = @import("sections.zig");
}
