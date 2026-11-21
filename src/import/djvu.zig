//! DjVu: только текстовый слой. Картинки страниц не читаются, распознавания нет.
//!
//! Файл — дерево IFF: «AT&T», затем FORM:DJVU (одна страница) или FORM:DJVM
//! (страницы подряд, каждая — своя FORM:DJVU). Текст страницы лежит в куске
//! TXTa (как есть) или TXTz (сжат BZZ): длина, UTF-8, затем дерево зон —
//! страница, колонка, область, абзац, строка, слово, знак — с прямоугольниками.
//! Из зон берутся строки с координатами, дальше работает та же сборка абзацев,
//! что и для PDF.
//!
//! BZZ — преобразование Барроуза — Уилера поверх двоичного арифметического
//! кодера ZP; таблица состояний кодера — из описания формата DjVu 3.
//!
//! Оглавление (NAVM) не читается: книга ложится одной главой.

const std = @import("std");
const cp = @import("../cp1251.zig");
const common = @import("common.zig");
const fb2 = @import("../fb2.zig");
const pdf = @import("pdf.zig");

const Parsed = fb2.Parsed;
const Chapter = fb2.Chapter;
const Budget = common.Budget;
const Line = pdf.Line;

pub const Error = common.Error || error{NoText};

const max_pages = 50000;
const max_block = 4096 * 1024;

// ───────────── кодер ZP ─────────────

const State = struct { p: u16, m: u16, up: u8, dn: u8 };

fn states(comptime rows: anytype) [256]State {
    @setEvalBranchQuota(10000);
    var t = [_]State{.{ .p = 0, .m = 0, .up = 0, .dn = 0 }} ** 256;
    for (rows, 0..) |r, i| t[i] = .{ .p = r[0], .m = r[1], .up = r[2], .dn = r[3] };
    return t;
}

const table: [256]State = states(.{
    .{ 0x8000, 0x0000, 84, 145 }, .{ 0x8000, 0x0000, 3, 4 }, .{ 0x8000, 0x0000, 4, 3 }, .{ 0x6bbd, 0x10a5, 5, 1 }, .{ 0x6bbd, 0x10a5, 6, 2 }, .{ 0x5d45, 0x1f28, 7, 3 },
    .{ 0x5d45, 0x1f28, 8, 4 }, .{ 0x51b9, 0x2bd3, 9, 5 }, .{ 0x51b9, 0x2bd3, 10, 6 }, .{ 0x4813, 0x36e3, 11, 7 }, .{ 0x4813, 0x36e3, 12, 8 }, .{ 0x3fd5, 0x408c, 13, 9 },
    .{ 0x3fd5, 0x408c, 14, 10 }, .{ 0x38b1, 0x48fd, 15, 11 }, .{ 0x38b1, 0x48fd, 16, 12 }, .{ 0x3275, 0x505d, 17, 13 }, .{ 0x3275, 0x505d, 18, 14 }, .{ 0x2cfd, 0x56d0, 19, 15 },
    .{ 0x2cfd, 0x56d0, 20, 16 }, .{ 0x2825, 0x5c71, 21, 17 }, .{ 0x2825, 0x5c71, 22, 18 }, .{ 0x23ab, 0x615b, 23, 19 }, .{ 0x23ab, 0x615b, 24, 20 }, .{ 0x1f87, 0x65a5, 25, 21 },
    .{ 0x1f87, 0x65a5, 26, 22 }, .{ 0x1bbb, 0x6962, 27, 23 }, .{ 0x1bbb, 0x6962, 28, 24 }, .{ 0x1845, 0x6ca2, 29, 25 }, .{ 0x1845, 0x6ca2, 30, 26 }, .{ 0x1523, 0x6f74, 31, 27 },
    .{ 0x1523, 0x6f74, 32, 28 }, .{ 0x1253, 0x71e6, 33, 29 }, .{ 0x1253, 0x71e6, 34, 30 }, .{ 0x0fcf, 0x7404, 35, 31 }, .{ 0x0fcf, 0x7404, 36, 32 }, .{ 0x0d95, 0x75d6, 37, 33 },
    .{ 0x0d95, 0x75d6, 38, 34 }, .{ 0x0b9d, 0x7768, 39, 35 }, .{ 0x0b9d, 0x7768, 40, 36 }, .{ 0x09e3, 0x78c2, 41, 37 }, .{ 0x09e3, 0x78c2, 42, 38 }, .{ 0x0861, 0x79ea, 43, 39 },
    .{ 0x0861, 0x79ea, 44, 40 }, .{ 0x0711, 0x7ae7, 45, 41 }, .{ 0x0711, 0x7ae7, 46, 42 }, .{ 0x05f1, 0x7bbe, 47, 43 }, .{ 0x05f1, 0x7bbe, 48, 44 }, .{ 0x04f9, 0x7c75, 49, 45 },
    .{ 0x04f9, 0x7c75, 50, 46 }, .{ 0x0425, 0x7d0f, 51, 47 }, .{ 0x0425, 0x7d0f, 52, 48 }, .{ 0x0371, 0x7d91, 53, 49 }, .{ 0x0371, 0x7d91, 54, 50 }, .{ 0x02d9, 0x7dfe, 55, 51 },
    .{ 0x02d9, 0x7dfe, 56, 52 }, .{ 0x0259, 0x7e5a, 57, 53 }, .{ 0x0259, 0x7e5a, 58, 54 }, .{ 0x01ed, 0x7ea6, 59, 55 }, .{ 0x01ed, 0x7ea6, 60, 56 }, .{ 0x0193, 0x7ee6, 61, 57 },
    .{ 0x0193, 0x7ee6, 62, 58 }, .{ 0x0149, 0x7f1a, 63, 59 }, .{ 0x0149, 0x7f1a, 64, 60 }, .{ 0x010b, 0x7f45, 65, 61 }, .{ 0x010b, 0x7f45, 66, 62 }, .{ 0x00d5, 0x7f6b, 67, 63 },
    .{ 0x00d5, 0x7f6b, 68, 64 }, .{ 0x00a5, 0x7f8d, 69, 65 }, .{ 0x00a5, 0x7f8d, 70, 66 }, .{ 0x007b, 0x7faa, 71, 67 }, .{ 0x007b, 0x7faa, 72, 68 }, .{ 0x0057, 0x7fc3, 73, 69 },
    .{ 0x0057, 0x7fc3, 74, 70 }, .{ 0x003b, 0x7fd7, 75, 71 }, .{ 0x003b, 0x7fd7, 76, 72 }, .{ 0x0023, 0x7fe7, 77, 73 }, .{ 0x0023, 0x7fe7, 78, 74 }, .{ 0x0013, 0x7ff2, 79, 75 },
    .{ 0x0013, 0x7ff2, 80, 76 }, .{ 0x0007, 0x7ffa, 81, 77 }, .{ 0x0007, 0x7ffa, 82, 78 }, .{ 0x0001, 0x7fff, 81, 79 }, .{ 0x0001, 0x7fff, 82, 80 }, .{ 0x5695, 0x0000, 9, 85 },
    .{ 0x24ee, 0x0000, 86, 226 }, .{ 0x8000, 0x0000, 5, 6 }, .{ 0x0d30, 0x0000, 88, 176 }, .{ 0x481a, 0x0000, 89, 143 }, .{ 0x0481, 0x0000, 90, 138 }, .{ 0x3579, 0x0000, 91, 141 },
    .{ 0x017a, 0x0000, 92, 112 }, .{ 0x24ef, 0x0000, 93, 135 }, .{ 0x007b, 0x0000, 94, 104 }, .{ 0x1978, 0x0000, 95, 133 }, .{ 0x0028, 0x0000, 96, 100 }, .{ 0x10ca, 0x0000, 97, 129 },
    .{ 0x000d, 0x0000, 82, 98 }, .{ 0x0b5d, 0x0000, 99, 127 }, .{ 0x0034, 0x0000, 76, 72 }, .{ 0x078a, 0x0000, 101, 125 }, .{ 0x00a0, 0x0000, 70, 102 }, .{ 0x050f, 0x0000, 103, 123 },
    .{ 0x0117, 0x0000, 66, 60 }, .{ 0x0358, 0x0000, 105, 121 }, .{ 0x01ea, 0x0000, 106, 110 }, .{ 0x0234, 0x0000, 107, 119 }, .{ 0x0144, 0x0000, 66, 108 }, .{ 0x0173, 0x0000, 109, 117 },
    .{ 0x0234, 0x0000, 60, 54 }, .{ 0x00f5, 0x0000, 111, 115 }, .{ 0x0353, 0x0000, 56, 48 }, .{ 0x00a1, 0x0000, 69, 113 }, .{ 0x05c5, 0x0000, 114, 134 }, .{ 0x011a, 0x0000, 65, 59 },
    .{ 0x03cf, 0x0000, 116, 132 }, .{ 0x01aa, 0x0000, 61, 55 }, .{ 0x0285, 0x0000, 118, 130 }, .{ 0x0286, 0x0000, 57, 51 }, .{ 0x01ab, 0x0000, 120, 128 }, .{ 0x03d3, 0x0000, 53, 47 },
    .{ 0x011a, 0x0000, 122, 126 }, .{ 0x05c5, 0x0000, 49, 41 }, .{ 0x00ba, 0x0000, 124, 62 }, .{ 0x08ad, 0x0000, 43, 37 }, .{ 0x007a, 0x0000, 72, 66 }, .{ 0x0ccc, 0x0000, 39, 31 },
    .{ 0x01eb, 0x0000, 60, 54 }, .{ 0x1302, 0x0000, 33, 25 }, .{ 0x02e6, 0x0000, 56, 50 }, .{ 0x1b81, 0x0000, 29, 131 }, .{ 0x045e, 0x0000, 52, 46 }, .{ 0x24ef, 0x0000, 23, 17 },
    .{ 0x0690, 0x0000, 48, 40 }, .{ 0x2865, 0x0000, 23, 15 }, .{ 0x09de, 0x0000, 42, 136 }, .{ 0x3987, 0x0000, 137, 7 }, .{ 0x0dc8, 0x0000, 38, 32 }, .{ 0x2c99, 0x0000, 21, 139 },
    .{ 0x10ca, 0x0000, 140, 172 }, .{ 0x3b5f, 0x0000, 15, 9 }, .{ 0x0b5d, 0x0000, 142, 170 }, .{ 0x5695, 0x0000, 9, 85 }, .{ 0x078a, 0x0000, 144, 168 }, .{ 0x8000, 0x0000, 141, 248 },
    .{ 0x050f, 0x0000, 146, 166 }, .{ 0x24ee, 0x0000, 147, 247 }, .{ 0x0358, 0x0000, 148, 164 }, .{ 0x0d30, 0x0000, 149, 197 }, .{ 0x0234, 0x0000, 150, 162 }, .{ 0x0481, 0x0000, 151, 95 },
    .{ 0x0173, 0x0000, 152, 160 }, .{ 0x017a, 0x0000, 153, 173 }, .{ 0x00f5, 0x0000, 154, 158 }, .{ 0x007b, 0x0000, 155, 165 }, .{ 0x00a1, 0x0000, 70, 156 }, .{ 0x0028, 0x0000, 157, 161 },
    .{ 0x011a, 0x0000, 66, 60 }, .{ 0x000d, 0x0000, 81, 159 }, .{ 0x01aa, 0x0000, 62, 56 }, .{ 0x0034, 0x0000, 75, 71 }, .{ 0x0286, 0x0000, 58, 52 }, .{ 0x00a0, 0x0000, 69, 163 },
    .{ 0x03d3, 0x0000, 54, 48 }, .{ 0x0117, 0x0000, 65, 59 }, .{ 0x05c5, 0x0000, 50, 42 }, .{ 0x01ea, 0x0000, 167, 171 }, .{ 0x08ad, 0x0000, 44, 38 }, .{ 0x0144, 0x0000, 65, 169 },
    .{ 0x0ccc, 0x0000, 40, 32 }, .{ 0x0234, 0x0000, 59, 53 }, .{ 0x1302, 0x0000, 34, 26 }, .{ 0x0353, 0x0000, 55, 47 }, .{ 0x1b81, 0x0000, 30, 174 }, .{ 0x05c5, 0x0000, 175, 193 },
    .{ 0x24ef, 0x0000, 24, 18 }, .{ 0x03cf, 0x0000, 177, 191 }, .{ 0x2b74, 0x0000, 178, 222 }, .{ 0x0285, 0x0000, 179, 189 }, .{ 0x201d, 0x0000, 180, 218 }, .{ 0x01ab, 0x0000, 181, 187 },
    .{ 0x1715, 0x0000, 182, 216 }, .{ 0x011a, 0x0000, 183, 185 }, .{ 0x0fb7, 0x0000, 184, 214 }, .{ 0x00ba, 0x0000, 69, 61 }, .{ 0x0a67, 0x0000, 186, 212 }, .{ 0x01eb, 0x0000, 59, 53 },
    .{ 0x06e7, 0x0000, 188, 210 }, .{ 0x02e6, 0x0000, 55, 49 }, .{ 0x0496, 0x0000, 190, 208 }, .{ 0x045e, 0x0000, 51, 45 }, .{ 0x030d, 0x0000, 192, 206 }, .{ 0x0690, 0x0000, 47, 39 },
    .{ 0x0206, 0x0000, 194, 204 }, .{ 0x09de, 0x0000, 41, 195 }, .{ 0x0155, 0x0000, 196, 202 }, .{ 0x0dc8, 0x0000, 37, 31 }, .{ 0x00e1, 0x0000, 198, 200 }, .{ 0x2b74, 0x0000, 199, 243 },
    .{ 0x0094, 0x0000, 72, 64 }, .{ 0x201d, 0x0000, 201, 239 }, .{ 0x0188, 0x0000, 62, 56 }, .{ 0x1715, 0x0000, 203, 237 }, .{ 0x0252, 0x0000, 58, 52 }, .{ 0x0fb7, 0x0000, 205, 235 },
    .{ 0x0383, 0x0000, 54, 48 }, .{ 0x0a67, 0x0000, 207, 233 }, .{ 0x0547, 0x0000, 50, 44 }, .{ 0x06e7, 0x0000, 209, 231 }, .{ 0x07e2, 0x0000, 46, 38 }, .{ 0x0496, 0x0000, 211, 229 },
    .{ 0x0bc0, 0x0000, 40, 34 }, .{ 0x030d, 0x0000, 213, 227 }, .{ 0x1178, 0x0000, 36, 28 }, .{ 0x0206, 0x0000, 215, 225 }, .{ 0x19da, 0x0000, 30, 22 }, .{ 0x0155, 0x0000, 217, 223 },
    .{ 0x24ef, 0x0000, 26, 16 }, .{ 0x00e1, 0x0000, 219, 221 }, .{ 0x320e, 0x0000, 20, 220 }, .{ 0x0094, 0x0000, 71, 63 }, .{ 0x432a, 0x0000, 14, 8 }, .{ 0x0188, 0x0000, 61, 55 },
    .{ 0x447d, 0x0000, 14, 224 }, .{ 0x0252, 0x0000, 57, 51 }, .{ 0x5ece, 0x0000, 8, 2 }, .{ 0x0383, 0x0000, 53, 47 }, .{ 0x8000, 0x0000, 228, 87 }, .{ 0x0547, 0x0000, 49, 43 },
    .{ 0x481a, 0x0000, 230, 246 }, .{ 0x07e2, 0x0000, 45, 37 }, .{ 0x3579, 0x0000, 232, 244 }, .{ 0x0bc0, 0x0000, 39, 33 }, .{ 0x24ef, 0x0000, 234, 238 }, .{ 0x1178, 0x0000, 35, 27 },
    .{ 0x1978, 0x0000, 138, 236 }, .{ 0x19da, 0x0000, 29, 21 }, .{ 0x2865, 0x0000, 24, 16 }, .{ 0x24ef, 0x0000, 25, 15 }, .{ 0x3987, 0x0000, 240, 8 }, .{ 0x320e, 0x0000, 19, 241 },
    .{ 0x2c99, 0x0000, 22, 242 }, .{ 0x432a, 0x0000, 13, 7 }, .{ 0x3b5f, 0x0000, 16, 10 }, .{ 0x447d, 0x0000, 13, 245 }, .{ 0x5695, 0x0000, 10, 2 }, .{ 0x5ece, 0x0000, 7, 1 },
    .{ 0x8000, 0x0000, 244, 83 }, .{ 0x8000, 0x0000, 249, 250 }, .{ 0x5695, 0x0000, 10, 2 }, .{ 0x481a, 0x0000, 89, 143 }, .{ 0x481a, 0x0000, 230, 246 },
});

const Zp = struct {
    src: []const u8,
    pos: usize = 0,
    a: u32 = 0,
    code: u32 = 0,
    fence: u32 = 0,
    buffer: u32 = 0,
    scount: u32 = 0,
    /// сколько байт 0xFF разрешено дочитать за концом данных
    delay: u32 = 25,

    fn init(src: []const u8) error{Damaged}!Zp {
        var z = Zp{ .src = src };
        const b0: u32 = z.byte() orelse 0xff;
        const b1: u32 = z.byte() orelse 0xff;
        z.code = (b0 << 8) | b1;
        try z.preload();
        z.fence = @min(z.code, 0x7fff);
        return z;
    }

    fn byte(z: *Zp) ?u8 {
        if (z.pos >= z.src.len) return null;
        z.pos += 1;
        return z.src[z.pos - 1];
    }

    fn preload(z: *Zp) error{Damaged}!void {
        while (z.scount <= 24) {
            const b: u32 = z.byte() orelse blk: {
                z.delay -= 1;
                if (z.delay < 1) return error.Damaged;
                break :blk 0xff;
            };
            z.buffer = (z.buffer << 8) | b;
            z.scount += 8;
        }
    }

    fn lps(z: *Zp, z_in: u32) error{Damaged}!void {
        const d = 0x10000 - z_in;
        z.a = (z.a + d) & 0xffff;
        z.code = (z.code + d) & 0xffff;
        // сдвиг — число единиц подряд в старших битах
        const shift: u32 = @clz(~@as(u16, @truncate(z.a)));
        if (shift == 0 or shift > 16 or shift > z.scount) return error.Damaged;
        z.scount -= shift;
        z.a = (z.a << @intCast(shift)) & 0xffff;
        z.code = ((z.code << @intCast(shift)) & 0xffff) | ((z.buffer >> @intCast(z.scount)) & ((@as(u32, 1) << @intCast(shift)) - 1));
        if (z.scount < 16) try z.preload();
        z.fence = @min(z.code, 0x7fff);
    }

    fn mps(z: *Zp, z_in: u32) error{Damaged}!void {
        z.scount -= 1;
        z.a = (z_in << 1) & 0xffff;
        z.code = ((z.code << 1) & 0xffff) | ((z.buffer >> @intCast(z.scount)) & 1);
        if (z.scount < 16) try z.preload();
        z.fence = @min(z.code, 0x7fff);
    }

    /// Бит с подстройкой вероятности.
    fn bit(z: *Zp, ctx: *u8) error{Damaged}!u1 {
        const st = table[ctx.*];
        var zz: u32 = z.a + st.p;
        const guess: u1 = @truncate(ctx.*);
        if (zz <= z.fence) {
            z.a = zz;
            return guess;
        }
        const d = 0x6000 + ((zz + z.a) >> 2);
        if (zz > d) zz = d;
        if (zz > z.code) {
            ctx.* = st.dn;
            try z.lps(zz);
            return guess ^ 1;
        }
        if (z.a >= st.m) ctx.* = st.up;
        try z.mps(zz);
        return guess;
    }

    /// Бит без модели: вероятность одна вторая.
    fn raw(z: *Zp) error{Damaged}!u1 {
        const zz = 0x8000 + (z.a >> 1);
        if (zz > z.code) {
            try z.lps(zz);
            return 1;
        }
        try z.mps(zz);
        return 0;
    }
};

// ───────────── BZZ ─────────────

fn tree(z: *Zp, ctx: []u8, bits: u4) error{Damaged}!usize {
    var n: usize = 1;
    const m = @as(usize, 1) << bits;
    while (n < m) n = (n << 1) | try z.bit(&ctx[n - 1]);
    return n - m;
}

/// Распаковывает поток BZZ целиком.
pub fn bzz(a: std.mem.Allocator, data: []const u8, budget: *Budget) common.Error![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var z = try Zp.init(data);
    var ctx = [_]u8{0} ** 300;
    while (true) {
        var size: usize = 1;
        while (size < (1 << 24)) size = (size << 1) | try z.raw();
        size -= 1 << 24;
        if (size == 0) break;
        if (size > max_block) return error.Damaged;
        try budget.take(size * 6);
        const block = try a.alloc(u8, size);
        defer a.free(block);

        var fshift: u5 = 0;
        if (try z.raw() == 1) {
            fshift += 1;
            if (try z.raw() == 1) fshift += 1;
        }
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, i| m.* = @intCast(i);
        var freq = [_]u32{0} ** 4;
        var fadd: u32 = 4;
        var mtfno: usize = 3;
        var marker: ?usize = null;
        for (block, 0..) |*slot, i| {
            const id: usize = @min(mtfno, 2);
            if (try z.bit(&ctx[id]) == 1) {
                mtfno = 0;
            } else if (try z.bit(&ctx[3 + id]) == 1) {
                mtfno = 1;
            } else found: {
                // дальше — диапазоны 2..3, 4..7, … 128..255, у каждого свои контексты
                var at: usize = 6;
                inline for (1..8) |bits| {
                    if (try z.bit(&ctx[at]) == 1) {
                        mtfno = (@as(usize, 1) << bits) + try tree(&z, ctx[at + 1 ..], bits);
                        break :found;
                    }
                    at += @as(usize, 1) << bits;
                }
                // конец строки преобразования: такой знак в блоке один
                mtfno = 256;
                slot.* = 0;
                marker = i;
                continue;
            }
            const c = mtf[mtfno];
            slot.* = c;
            // знак встаёт в очередь по накопленной частоте
            fadd += fadd >> fshift;
            if (fadd > 0x10000000) {
                fadd >>= 24;
                for (&freq) |*f| f.* >>= 24;
            }
            var fc = fadd;
            if (mtfno < freq.len) fc +%= freq[mtfno];
            var k = mtfno;
            while (k >= freq.len) : (k -= 1) mtf[k] = mtf[k - 1];
            while (k > 0 and fc >= freq[k - 1]) : (k -= 1) {
                mtf[k] = mtf[k - 1];
                freq[k] = freq[k - 1];
            }
            mtf[k] = c;
            freq[k] = fc;
        }

        // обратное преобразование Барроуза — Уилера
        const mark = marker orelse return error.Damaged;
        if (mark < 1) return error.Damaged;
        const posn = try a.alloc(u32, size);
        defer a.free(posn);
        var count = [_]u32{0} ** 256;
        for (block, 0..) |c, i| {
            if (i == mark) {
                posn[i] = 0;
                continue;
            }
            posn[i] = (@as(u32, c) << 24) | (count[c] & 0xffffff);
            count[c] += 1;
        }
        var last: u32 = 1;
        for (&count) |*n| {
            const t = n.*;
            n.* = last;
            last += t;
        }
        const start = out.items.len;
        try out.resize(start + size - 1);
        const dst = out.items[start..];
        var i: usize = 0;
        var left = size - 1;
        while (left > 0) {
            if (i >= size or i == mark) return error.Damaged;
            const n = posn[i];
            const c: u8 = @intCast(n >> 24);
            left -= 1;
            dst[left] = c;
            i = count[c] + (n & 0xffffff);
        }
        if (i != mark) return error.Damaged;
    }
    return out.items;
}

// ───────────── IFF ─────────────

const Chunk = struct { id: []const u8, kind: []const u8, data: []const u8 };

const Chunks = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(c: *Chunks) ?Chunk {
        if (c.pos + 8 > c.data.len) return null;
        const id = c.data[c.pos..][0..4];
        const size = std.mem.readInt(u32, c.data[c.pos + 4 ..][0..4], .big);
        const from = c.pos + 8;
        const to = from + @min(size, c.data.len - from); // оборванный файл: что есть
        c.pos = to + (to & 1);
        var out = Chunk{ .id = id, .kind = "", .data = c.data[from..to] };
        if (std.mem.eql(u8, id, "FORM") and out.data.len >= 4) {
            out.kind = out.data[0..4];
            out.data = out.data[4..];
        }
        return out;
    }
};

pub fn looksLike(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "AT&TFORM");
}

// ───────────── текстовый слой ─────────────

const Reader = struct {
    d: []const u8,
    pos: usize = 0,

    fn int(r: *Reader, comptime n: usize) error{Damaged}!u32 {
        if (r.pos + n > r.d.len) return error.Damaged;
        var v: u32 = 0;
        for (r.d[r.pos..][0..n]) |b| v = (v << 8) | b;
        r.pos += n;
        return v;
    }
};

const Rect = struct { x: i64 = 0, y: i64 = 0, w: i64 = 0, h: i64 = 0 };

const Zone = struct { kind: u8, rect: Rect, start: i64, len: i64 };

const zone_line = 5;

/// Знаки, которыми в тексте слоя кончаются строка, абзац, область, колонка.
const breaks = "\n\x0b\x1d\x1f";

fn isBreak(c: u8) bool {
    return std.mem.indexOfScalar(u8, breaks, c) != null;
}

const Layer = struct {
    a: std.mem.Allocator,
    r: Reader,
    text: []const u8,
    page: u32,
    lines: *std.ArrayListUnmanaged(Line),
    budget: *Budget,
    /// сколько зон ещё можно прочесть: защита от раздутого дерева
    zones_left: usize = 4 << 20,
    /// слова и знаки, не вошедшие ни в одну зону строки
    loose: std.ArrayListUnmanaged(Zone) = .{},

    fn zone(l: *Layer, parent: ?Zone, prev: ?Zone, inside_line: bool) common.Error!Zone {
        if (l.zones_left == 0) return error.Damaged;
        l.zones_left -= 1;
        const kind: u8 = @intCast(try l.r.int(1));
        if (kind < 1 or kind > 7) return error.Damaged;
        if (parent) |p| if (kind <= p.kind) return error.Damaged; // глубина не больше семи
        var x: i64 = @as(i64, try l.r.int(2)) - 0x8000;
        var y: i64 = @as(i64, try l.r.int(2)) - 0x8000;
        const w: i64 = @as(i64, try l.r.int(2)) - 0x8000;
        const h: i64 = @as(i64, try l.r.int(2)) - 0x8000;
        var start: i64 = @as(i64, try l.r.int(2)) - 0x8000;
        const len: i64 = try l.r.int(3);
        if (prev) |p| {
            if (kind == 1 or kind == 4 or kind == 5) {
                x += p.rect.x;
                y = p.rect.y - (y + h);
            } else {
                x += p.rect.x + p.rect.w;
                y += p.rect.y;
            }
            start += p.start + p.len;
        } else if (parent) |p| {
            x += p.rect.x;
            y = p.rect.y + p.rect.h - (y + h);
            start += p.start;
        }
        if (start < 0 or start + len > l.text.len) return error.Damaged;
        const me = Zone{ .kind = kind, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .start = start, .len = len };
        var children = try l.r.int(3);
        const is_line = kind == zone_line;
        if (!inside_line) {
            if (kind > zone_line) {
                // слово вне строки: строку ему найдут по тексту
                try l.budget.take(@sizeOf(Zone));
                try l.loose.append(l.a, me);
            } else if (is_line or children == 0) try l.emit(me);
        }
        var before: ?Zone = null;
        while (children > 0) : (children -= 1) before = try l.zone(me, before, inside_line or kind >= zone_line);
        return me;
    }

    /// Слова без зон строк: строки — как разбит текст страницы, место строки —
    /// общий прямоугольник её слов.
    fn looseLines(l: *Layer) common.Error!void {
        const words = l.loose.items;
        if (words.len == 0) return;
        var wi: usize = 0;
        var last = Rect{};
        var from: usize = 0;
        while (from < l.text.len) {
            var to = from;
            while (to < l.text.len and !isBreak(l.text[to])) to += 1;
            var box: ?Rect = null;
            while (wi < words.len) : (wi += 1) {
                const w = words[wi];
                // слово принадлежит строке, где стоит его первая буква: знак конца
                // строки бывает приклеен к началу следующего слова
                var at: usize = @intCast(w.start);
                const end: usize = @intCast(w.start + w.len);
                while (at < end and (isBreak(l.text[at]) or l.text[at] == ' ')) at += 1;
                if (at >= to and at < end) break;
                if (at < from or at == end) continue;
                if (box) |b| {
                    const x0 = @min(b.x, w.rect.x);
                    const y0 = @min(b.y, w.rect.y);
                    box = .{ .x = x0, .y = y0, .w = @max(b.x + b.w, w.rect.x + w.rect.w) - x0, .h = @max(b.y + b.h, w.rect.y + w.rect.h) - y0 };
                } else box = w.rect;
            }
            if (box) |b| last = b;
            try l.emit(.{ .kind = zone_line, .rect = last, .start = @intCast(from), .len = @intCast(to - from) });
            from = to + 1;
        }
    }

    fn emit(l: *Layer, z: Zone) common.Error!void {
        const raw = l.text[@intCast(z.start)..@intCast(z.start + z.len)];
        // зона крупнее строки могла принести несколько строк текста
        var parts = std.mem.tokenizeAny(u8, raw, breaks);
        while (parts.next()) |part| {
            const t = try clean(l.a, part, l.budget);
            if (t.len == 0) continue;
            try l.lines.append(l.a, .{
                .x0 = @floatFromInt(z.rect.x),
                .x1 = @floatFromInt(z.rect.x + z.rect.w),
                .y = @floatFromInt(z.rect.y),
                .size = @floatFromInt(@max(z.rect.h, 1)),
                .text = .{ .items = @constCast(t), .capacity = t.len },
                .page = l.page,
            });
        }
    }
};

/// Строка UTF-8 → windows-1251: пробелы схлопнуты, управляющие знаки убраны.
fn clean(a: std.mem.Allocator, s: []const u8, budget: *Budget) common.Error![]const u8 {
    try budget.take(s.len + 1);
    var out = try std.ArrayList(u8).initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var u: u21 = 0xFFFD;
        if (i + n <= s.len) u = std.unicode.utf8Decode(s[i..][0..n]) catch 0xFFFD;
        i += if (u == 0xFFFD) 1 else n;
        if (u == 0xFFFD) continue;
        if (u < 0x20 or u == 0x7f or u == 0xA0) u = ' ';
        const piece = if (u == 0xAC) "-" else common.fromUnicode(u); // «¬» ставят на месте переноса
        if (piece.len == 1 and piece[0] == ' ' and (out.items.len == 0 or out.items[out.items.len - 1] == ' ')) continue;
        try out.appendSlice(piece);
    }
    return std.mem.trimRight(u8, out.items, " ");
}

/// Текстовый слой одной страницы → строки.
fn layer(a: std.mem.Allocator, data: []const u8, index: u32, lines: *std.ArrayListUnmanaged(Line), budget: *Budget) common.Error!void {
    var r = Reader{ .d = data };
    const n = r.int(3) catch return;
    if (n > data.len - r.pos) return;
    const text = data[r.pos..][0..n];
    r.pos += n;
    const before = lines.items.len;
    var l = Layer{ .a = a, .r = r, .text = text, .page = index, .lines = lines, .budget = budget };
    const ok = blk: {
        const version = l.r.int(1) catch break :blk false;
        if (version != 1) break :blk false;
        _ = l.zone(null, null, false) catch |err| switch (err) {
            error.Damaged => break :blk false,
            else => |e| return e,
        };
        try l.looseLines();
        break :blk lines.items.len > before;
    };
    if (ok) {
        // высота строки скачет от букв с выносными: всем строкам страницы — обычная
        const page_lines = lines.items[before..];
        const hs = try a.alloc(f64, page_lines.len);
        for (hs, page_lines) |*h, pl| h.* = pl.size;
        std.mem.sort(f64, hs, {}, std.sort.asc(f64));
        for (page_lines) |*pl| pl.size = hs[hs.len / 2];
        // скан перекошен: левый край ползёт от строки к строке. Отступ строки
        // считается от края соседних строк, а не от края всей страницы.
        const xs = try a.alloc(f64, page_lines.len);
        var edge = std.math.inf(f64);
        for (xs, page_lines) |*x, pl| {
            x.* = pl.x0;
            edge = @min(edge, pl.x0);
        }
        for (page_lines, 0..) |*pl, i| {
            var near = xs[i];
            for (xs[i -| 6..@min(xs.len, i + 7)]) |x| near = @min(near, x);
            pl.x0 = edge + (xs[i] - near);
        }
        return;
    }
    // зон нет или они испорчены: строки — как записаны в тексте, без координат
    lines.items.len = before;
    var parts = std.mem.tokenizeAny(u8, text, breaks);
    var row: f64 = 0;
    while (parts.next()) |part| {
        const t = try clean(a, part, budget);
        if (t.len == 0) continue;
        row += 1;
        // мерка — знаки: строка короче самой длинной на дюжину знаков считается неполной
        try lines.append(a, .{ .x0 = 0, .x1 = @floatFromInt(t.len), .y = -5 * row, .size = 4, .text = .{ .items = @constCast(t), .capacity = t.len }, .page = index });
    }
}

fn page(a: std.mem.Allocator, data: []const u8, index: u32, lines: *std.ArrayListUnmanaged(Line), budget: *Budget) common.Error!void {
    var parts = Chunks{ .data = data };
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.id, "TXTa")) return layer(a, part.data, index, lines, budget);
        if (std.mem.eql(u8, part.id, "TXTz")) {
            // испорченный слой одной страницы книгу не губит
            const plain = bzz(a, part.data, budget) catch |err| switch (err) {
                error.Damaged => return,
                else => |e| return e,
            };
            return layer(a, plain, index, lines, budget);
        }
    }
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, budget: *Budget) Error!Parsed {
    if (!looksLike(bytes)) return error.Damaged;
    var top = Chunks{ .data = bytes[4..] };
    const root = top.next() orelse return error.Damaged;
    var lines = std.ArrayListUnmanaged(Line){};
    var pages: u32 = 0;
    if (std.mem.eql(u8, root.kind, "DJVU")) {
        try page(a, root.data, 0, &lines, budget);
        pages = 1;
    } else if (std.mem.eql(u8, root.kind, "DJVM")) {
        var parts = Chunks{ .data = root.data };
        while (parts.next()) |part| {
            if (!std.mem.eql(u8, part.kind, "DJVU")) continue;
            if (pages >= max_pages) return error.TooBig;
            try page(a, part.data, pages, &lines, budget);
            pages += 1;
        }
    } else return error.Damaged;

    var letters: usize = 0;
    for (lines.items) |l| letters += l.text.items.len;
    if (letters < 200) return error.NoText;

    const kept = try pdf.stripRunning(a, lines.items, pages);
    const text = try pdf.paragraphs(a, kept, budget);
    if (text.len == 0) return error.NoText;
    const chapters = try a.alloc(Chapter, 1);
    chapters[0] = .{ .title = cp.text("Текст"), .text = text };
    return .{ .chapters = chapters };
}

// ───────────── тесты ─────────────

const TestLine = struct { x: i32, y: i32, w: i32, text: []const u8 };

fn put16(out: *std.ArrayList(u8), v: i32) !void {
    try out.writer().writeInt(u16, @intCast(v + 0x8000), .big);
}

/// Текстовый слой страницы: строки зонами (line_zones) или слова прямо в странице.
fn testLayer(a: std.mem.Allocator, rows: []const TestLine, line_zones: bool) ![]const u8 {
    var text = std.ArrayList(u8).init(a);
    var zones = std.ArrayList(u8).init(a);
    var count: u32 = 0;
    const page_h = 2000;
    var prev_x: i32 = 0;
    var prev_y: i32 = page_h; // для первой зоны — верх страницы
    var prev_end: i32 = 0;
    for (rows, 0..) |row, i| {
        const start: i32 = @intCast(text.items.len);
        // перевод строки приклеен к началу следующей строки, как в настоящих файлах
        if (i > 0) try text.append('\n');
        try text.appendSlice(row.text);
        const len: u24 = @intCast(@as(i32, @intCast(text.items.len)) - start);
        const h = 40;
        try zones.append(if (line_zones) 5 else 6);
        if (line_zones) {
            try put16(&zones, row.x - prev_x);
            try put16(&zones, prev_y - row.y - h);
        } else if (i == 0) {
            try put16(&zones, row.x);
            try put16(&zones, page_h - row.y - h);
        } else {
            try put16(&zones, row.x - prev_x); // от правого края прошлого слова
            try put16(&zones, row.y - prev_y);
        }
        try put16(&zones, row.w);
        try put16(&zones, h);
        try put16(&zones, start - prev_end);
        try zones.writer().writeInt(u24, len, .big);
        try zones.writer().writeInt(u24, 0, .big);
        prev_x = if (line_zones) row.x else row.x + row.w;
        prev_y = row.y;
        prev_end = start + len;
        count += 1;
    }
    var out = std.ArrayList(u8).init(a);
    try out.writer().writeInt(u24, @intCast(text.items.len), .big);
    try out.appendSlice(text.items);
    try out.append(1); // версия
    try out.append(1); // зона страницы
    try put16(&out, 0);
    try put16(&out, 0);
    try put16(&out, 1500);
    try put16(&out, page_h);
    try put16(&out, 0);
    try out.writer().writeInt(u24, @intCast(text.items.len), .big);
    try out.writer().writeInt(u24, @intCast(count), .big);
    try out.appendSlice(zones.items);
    return out.items;
}

fn testChunk(out: *std.ArrayList(u8), id: []const u8, data: []const u8) !void {
    try out.appendSlice(id);
    try out.writer().writeInt(u32, @intCast(data.len), .big);
    try out.appendSlice(data);
    if (data.len & 1 == 1) try out.append(0);
}

/// Книга из страниц; каждая страница — готовый кусок (TXTa или TXTz) либо ничего.
fn testBook(a: std.mem.Allocator, layers: []const ?[]const u8, id: []const u8) ![]const u8 {
    var body = std.ArrayList(u8).init(a);
    try body.appendSlice("DJVM");
    try testChunk(&body, "DIRM", "\x00\x00\x00");
    for (layers) |maybe| {
        var pg = std.ArrayList(u8).init(a);
        try pg.appendSlice("DJVU");
        try testChunk(&pg, "INFO", "\x05\xdc\x07\xd0\x18\x00\x2c\x01\x16\x01");
        if (maybe) |l| try testChunk(&pg, id, l);
        try testChunk(&body, "FORM", pg.items);
    }
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("AT&T");
    try testChunk(&out, "FORM", body.items);
    return out.items;
}

const test_rows = [_]TestLine{
    .{ .x = 160, .y = 1800, .w = 1240, .text = "Степь тянулась до самого края неба, и дорога в ней каза-" },
    .{ .x = 100, .y = 1740, .w = 1300, .text = "лась бесконечной: ни дерева, ни жилья, только трава да ветер." },
    .{ .x = 100, .y = 1680, .w = 700, .text = "Ехали молча, каждый думал о своём." },
    .{ .x = 160, .y = 1620, .w = 1240, .text = "К вечеру показались огни, и лошади пошли веселее, чуя" },
    .{ .x = 100, .y = 1560, .w = 1300, .text = "близкий отдых; возница запел что-то протяжное и старое," },
    .{ .x = 100, .y = 1500, .w = 520, .text = "а мальчик уснул на тюках." },
};

const test_want =
    "Степь тянулась до самого края неба, и дорога в ней казалась бесконечной: ни дерева, ни жилья, только трава да ветер. Ехали молча, каждый думал о своём.\n\n" ++
    "К вечеру показались огни, и лошади пошли веселее, чуя близкий отдых; возница запел что-то протяжное и старое, а мальчик уснул на тюках.";

test "DjVu: настоящий кусок BZZ распаковывается" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget = Budget{ .left = 1 << 20 };
    // текстовый слой одной страницы общедоступной книги 1893 года
    const plain = try bzz(arena.allocator(), @embedFile("djvu_sample.bzz"), &budget);
    try std.testing.expectEqual(@as(usize, 309), plain.len);
    const want = "Дозволено Цензурою\nВаршава, 5 Октября 1893 года.";
    try std.testing.expectEqual(@as(usize, want.len + 1), std.mem.readInt(u24, plain[0..3], .big));
    try std.testing.expectEqualStrings(want, plain[3..][0..want.len]);
}

test "DjVu: строки зонами и слова без зон строк собираются в абзацы" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ true, false }) |line_zones| {
        const l = try testLayer(a, &test_rows, line_zones);
        const book = try testBook(a, &.{ null, l, null }, "TXTa");
        var budget = Budget{ .left = 8 << 20 };
        const parsed = try parse(a, book, &budget);
        try std.testing.expectEqual(@as(usize, 1), parsed.chapters.len);
        try std.testing.expectEqualStrings(cp.text(test_want), parsed.chapters[0].text);
    }
}

test "DjVu: слой без зон, пустая книга, обрывки" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget = Budget{ .left = 64 << 20 };
    // только текст, дерева зон нет: строки как записаны
    var plain = std.ArrayList(u8).init(a);
    var text = std.ArrayList(u8).init(a);
    for (test_rows) |row| {
        try text.appendSlice(row.text);
        try text.append('\n');
    }
    try plain.writer().writeInt(u24, @intCast(text.items.len), .big);
    try plain.appendSlice(text.items);
    const parsed = try parse(a, try testBook(a, &.{plain.items}, "TXTa"), &budget);
    try std.testing.expect(std.mem.indexOf(u8, parsed.chapters[0].text, cp.text("казалась бесконечной")) != null);
    // скан без текстового слоя
    try std.testing.expectError(error.NoText, parse(a, try testBook(a, &.{ null, null }, "TXTa"), &budget));
    // сжатый слой испорчен: страница пропускается, книга без текста
    try std.testing.expectError(error.NoText, parse(a, try testBook(a, &.{"\x00\x01\x02мусор вместо сжатых данных"}, "TXTz"), &budget));
    try std.testing.expectError(error.Damaged, parse(a, "AT&TFORM", &budget));
    try std.testing.expectError(error.Damaged, parse(a, "AT&TFORM\x00\x00\x00\x04PM44", &budget));
    // любой обрывок книги разбирается без падения
    const book = try testBook(a, &.{try testLayer(a, &test_rows, true)}, "TXTa");
    for (0..book.len) |n| _ = parse(a, book[0..n], &budget) catch {};
}

test "DjVu: порченые файлы не роняют разбор" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0xD1F0);
    const rnd = prng.random();
    const sample = @embedFile("djvu_sample.bzz");
    const books = [_][]const u8{
        try testBook(a, &.{ try testLayer(a, &test_rows, true), try testLayer(a, &test_rows, false) }, "TXTa"),
        try testBook(a, &.{ sample, sample }, "TXTz"),
    };
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    for (0..6000) |round| {
        _ = scratch.reset(.retain_capacity);
        const sa = scratch.allocator();
        const buf = try sa.dupe(u8, books[round % books.len]);
        for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| buf[rnd.uintLessThan(usize, buf.len)] = rnd.int(u8);
        var budget = Budget{ .left = 16 << 20 };
        _ = parse(sa, buf, &budget) catch {};
        // и сам распаковщик на порченом потоке
        const z = try sa.dupe(u8, sample);
        for (0..rnd.intRangeAtMost(usize, 1, 4)) |_| z[rnd.uintLessThan(usize, z.len)] = rnd.int(u8);
        var b2 = Budget{ .left = 16 << 20 };
        _ = bzz(sa, z[0..rnd.intRangeAtMost(usize, 0, z.len)], &b2) catch {};
    }
}
