//! Звук (BACKLOG_RU.md §22): разбор MP3, Ogg Vorbis, M4A (AAC) и запись MP3 «как до
//! 2003 года» — MPEG-1 Layer III, CBR 128 кбит/с, 32/44,1/48 кГц, тег ID3v1.
//!
//! Любой вход перекодируется, даже MP3: так у всех файлов сайта один вид, а
//! VBR, теги ID3v2 с картинками, Xing/LAME и MPEG-2.5 не доходят до старых
//! проигрывателей. Каналов больше двух — сводятся в стерео; частота, которой
//! нет у MPEG-1, пересчитывается в 44,1 кГц (окно sinc с окном Кайзера).

const std = @import("std");
pub const mp3dec = @import("mp3dec.zig");
pub const mp3enc = @import("mp3enc.zig");
pub const vorbis = @import("vorbis.zig");
pub const aac = @import("aac.zig");
pub const mdct = @import("mdct.zig");

pub const Kind = enum { mp3, ogg, m4a };

pub const Error = error{ NotAudio, Unsupported, Damaged, TooLong, OutOfMemory, WriteFailed };

/// Не длиннее суток: дольше — почти наверняка испорченный файл.
pub const max_seconds = 24 * 3600;

/// Вид файла по первым байтам.
pub fn detect(b: []const u8) ?Kind {
    if (b.len >= 8 and std.mem.eql(u8, b[4..8], "ftyp")) return .m4a;
    if (b.len >= 4 and std.mem.eql(u8, b[0..4], "OggS")) return .ogg;
    if (mp3dec.Decoder.init(b)) |_| return .mp3 else |_| {}
    return null;
}

pub fn ext(k: Kind) []const u8 {
    return switch (k) {
        .mp3 => ".mp3",
        .ogg => ".ogg",
        .m4a => ".m4a",
    };
}

/// Тег ID3v1 (байты как есть — у сайта windows-1251).
pub const Tag = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    year: []const u8 = "",
    comment: []const u8 = "",
    /// 101 — Speech (аудиокнига), 255 — не указан.
    genre: u8 = 255,
};

pub const Result = struct {
    /// Отсчётов на канал в MP3 (без хвоста кодера).
    samples: u64,
    rate: u32,
    channels: u8,
    bytes: u64,

    pub fn seconds(r: Result) u32 {
        return @intCast(r.samples / r.rate);
    }
};

/// Вход в любом из трёх видов → MP3 CBR 128 в `out`.
pub fn toMp3(gpa: std.mem.Allocator, data: []const u8, out: std.io.AnyWriter, tag: Tag) Error!Result {
    const kind = detect(data) orelse return error.NotAudio;
    var src = Source.open(gpa, kind, data) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        else => error.Damaged,
    };
    defer src.close(gpa);
    const in_ch = src.channels();
    const in_rate = src.rate();
    if (in_rate < 4000 or in_rate > 192000 or in_ch == 0) return error.Unsupported;
    const ch: u8 = if (in_ch == 1) 1 else 2;
    const rate: u32 = if (mp3enc.rateOk(in_rate)) in_rate else 44100;
    var enc = mp3enc.Encoder.init(out, rate, ch);
    var rs: ?Resampler = if (rate != in_rate) try Resampler.init(gpa, in_rate, rate, ch) else null;
    defer if (rs) |*x| x.deinit();
    var mix: [2][4096]f32 = undefined;
    const limit: u64 = @as(u64, max_seconds) * in_rate;
    var seen: u64 = 0;
    while (true) {
        const n = src.next();
        if (n == 0) break;
        seen += n;
        if (seen > limit) return error.TooLong;
        var done: usize = 0;
        while (done < n) {
            const k = @min(n - done, 4096);
            src.mix(done, k, ch, &mix);
            if (rs) |*x| {
                try x.push(mix[0][0..k], mix[1][0..k], &enc);
            } else {
                enc.push(mix[0][0..k], mix[1][0..k]) catch return error.WriteFailed;
            }
            done += k;
        }
    }
    if (rs) |*x| try x.flush(&enc);
    enc.finish() catch return error.WriteFailed;
    if (seen == 0) return error.Damaged;
    try writeTag(out, tag);
    return .{
        .samples = seen * rate / in_rate,
        .rate = rate,
        .channels = ch,
        .bytes = enc.bytes + 128,
    };
}

fn writeTag(out: std.io.AnyWriter, t: Tag) Error!void {
    var b = [_]u8{0} ** 128;
    @memcpy(b[0..3], "TAG");
    const put = struct {
        fn f(dst: []u8, s: []const u8) void {
            const n = @min(dst.len, s.len);
            @memcpy(dst[0..n], s[0..n]);
        }
    }.f;
    put(b[3..33], t.title);
    put(b[33..63], t.artist);
    put(b[63..93], t.album);
    put(b[93..97], t.year);
    put(b[97..125], t.comment);
    b[127] = t.genre;
    out.writeAll(&b) catch return error.WriteFailed;
}

/// Длительность готового MP3 сайта (CBR 128): по размеру без тега.
pub fn mp3Seconds(size: u64) u32 {
    const audio = if (size > 128) size - 128 else size;
    return @intCast(audio * 8 / (mp3enc.bitrate * 1000));
}

// ───────────── источники ─────────────

const Source = union(Kind) {
    mp3: mp3dec.Decoder,
    ogg: *vorbis.Decoder,
    m4a: *aac.Decoder,

    fn open(gpa: std.mem.Allocator, k: Kind, data: []const u8) !Source {
        return switch (k) {
            .mp3 => .{ .mp3 = try mp3dec.Decoder.init(data) },
            .ogg => .{ .ogg = try vorbis.Decoder.init(gpa, data) },
            .m4a => .{ .m4a = try aac.Decoder.init(gpa, data) },
        };
    }
    fn close(s: *Source, gpa: std.mem.Allocator) void {
        switch (s.*) {
            .mp3 => {},
            .ogg => |d| d.deinit(gpa),
            .m4a => |d| d.deinit(gpa),
        }
    }
    fn rate(s: *const Source) u32 {
        return switch (s.*) {
            .mp3 => |d| d.rate,
            .ogg => |d| d.rate,
            .m4a => |d| d.rate,
        };
    }
    fn channels(s: *const Source) u8 {
        return switch (s.*) {
            .mp3 => |d| d.channels,
            .ogg => |d| d.channels,
            .m4a => |d| d.channels,
        };
    }
    fn next(s: *Source) usize {
        return switch (s.*) {
            .mp3 => |*d| d.next(),
            .ogg => |d| d.next(),
            .m4a => |d| d.next(),
        };
    }
    fn chan(s: *const Source, c: usize) []const f32 {
        return switch (s.*) {
            .mp3 => |*d| &d.pcm[c],
            .ogg => |d| d.out[c],
            .m4a => |d| &d.out[c],
        };
    }

    /// Отсчёты [at, at+n) текущей порции, сведённые в `ch` каналов.
    fn mix(s: *const Source, at: usize, n: usize, ch: u8, out: *[2][4096]f32) void {
        const in = s.channels();
        if (in == 1) {
            @memcpy(out[0][0..n], s.chan(0)[at..][0..n]);
            if (ch == 2) @memcpy(out[1][0..n], out[0][0..n]);
            return;
        }
        if (in == 2) {
            @memcpy(out[0][0..n], s.chan(0)[at..][0..n]);
            @memcpy(out[1][0..n], s.chan(1)[at..][0..n]);
            return;
        }
        // больше двух: центр и тыл — в обе стороны с −3 дБ, НЧ-канал отбрасывается
        const k: f32 = 0.70710678;
        var l: usize = 0;
        var r: usize = 1;
        var c: ?usize = null;
        var ls: ?usize = null;
        var rsur: ?usize = null;
        switch (s.*) {
            // AAC: C, L, R, Ls, Rs, LFE
            .m4a => {
                c = 0;
                l = 1;
                r = 2;
                if (in >= 5) {
                    ls = 3;
                    rsur = 4;
                } else if (in == 4) ls = 3;
            },
            // Vorbis: 3 — L C R; 4 — L R Ls Rs; 5, 6 — L C R Ls Rs [LFE]
            else => switch (in) {
                3 => {
                    c = 1;
                    r = 2;
                },
                4 => {
                    ls = 2;
                    rsur = 3;
                },
                else => {
                    c = 1;
                    r = 2;
                    ls = 3;
                    rsur = 4;
                },
            },
        }
        const norm: f32 = 1.0 / (1.0 + (if (c != null) k else 0) + (if (ls != null) k else 0));
        for (0..n) |i| {
            var a = s.chan(l)[at + i];
            var b = s.chan(r)[at + i];
            if (c) |ci| {
                a += k * s.chan(ci)[at + i];
                b += k * s.chan(ci)[at + i];
            }
            if (ls) |x| a += k * s.chan(x)[at + i];
            if (rsur) |x| b += k * s.chan(x)[at + i] else if (ls) |x| b += k * s.chan(x)[at + i];
            out[0][i] = a * norm;
            out[1][i] = b * norm;
        }
        if (ch == 1) for (0..n) |i| {
            out[0][i] = (out[0][i] + out[1][i]) * 0.5;
        };
    }
};

// ───────────── пересчёт частоты ─────────────

/// Полифазный фильтр: sinc с окном Кайзера, таблица на 256 фаз с линейной
/// интерполяцией. Срез — 0,92 от меньшей из двух частот Найквиста.
const Resampler = struct {
    gpa: std.mem.Allocator,
    step: f64, // шаг по входу на один выходной отсчёт
    scale: f64, // сжатие ядра при понижении частоты
    half: usize, // полуширина ядра во входных отсчётах
    table: []f32,
    buf: [2]std.ArrayList(f32),
    pos: f64 = 0, // позиция следующего выходного отсчёта во входном буфере
    ch: u8,
    out: [2][1024]f32 = undefined,

    const taps = 16;
    const phases = 256;

    fn init(gpa: std.mem.Allocator, in_rate: u32, out_rate: u32, ch: u8) !Resampler {
        const step = @as(f64, @floatFromInt(in_rate)) / @as(f64, @floatFromInt(out_rate));
        const scale = @max(1.0, step);
        const half: usize = @intFromFloat(@ceil(taps * scale));
        const table = try gpa.alloc(f32, taps * phases + 1);
        const beta = 8.0;
        const cut = 0.92;
        for (table, 0..) |*t, i| {
            const x = @as(f64, @floatFromInt(i)) / phases; // 0..taps в единицах ядра
            const s = if (x == 0) 1.0 else @sin(std.math.pi * x * cut) / (std.math.pi * x * cut);
            const r = x / taps;
            const w = if (r >= 1) 0 else bessel0(beta * @sqrt(1 - r * r)) / bessel0(beta);
            t.* = @floatCast(s * w * cut);
        }
        var rs = Resampler{ .gpa = gpa, .step = step, .scale = scale, .half = half, .table = table, .buf = .{ std.ArrayList(f32).init(gpa), std.ArrayList(f32).init(gpa) }, .ch = ch };
        // начальная тишина, чтобы первый отсчёт видел ядро целиком
        for (0..ch) |c| try rs.buf[c].appendNTimes(0, half);
        rs.pos = @floatFromInt(half);
        return rs;
    }

    fn deinit(r: *Resampler) void {
        r.gpa.free(r.table);
        r.buf[0].deinit();
        r.buf[1].deinit();
    }

    fn kernel(r: *const Resampler, d: f64) f32 {
        const x = @abs(d) / r.scale * phases;
        if (x >= taps * phases) return 0;
        const i: usize = @intFromFloat(x);
        const f: f32 = @floatCast(x - @as(f64, @floatFromInt(i)));
        return r.table[i] + (r.table[i + 1] - r.table[i]) * f;
    }

    fn push(r: *Resampler, l: []const f32, rr: []const f32, enc: anytype) Error!void {
        try r.buf[0].appendSlice(l);
        if (r.ch == 2) try r.buf[1].appendSlice(rr);
        try r.drain(enc, false);
    }

    fn flush(r: *Resampler, enc: anytype) Error!void {
        for (0..r.ch) |c| try r.buf[c].appendNTimes(0, r.half + 1);
        try r.drain(enc, true);
    }

    fn drain(r: *Resampler, enc: anytype, final: bool) Error!void {
        _ = final;
        const len = r.buf[0].items.len;
        var n: usize = 0;
        const inv: f32 = @floatCast(1.0 / r.scale);
        while (r.pos + @as(f64, @floatFromInt(r.half)) + 1 < @as(f64, @floatFromInt(len))) {
            const center: usize = @intFromFloat(@floor(r.pos));
            const frac = r.pos - @as(f64, @floatFromInt(center));
            for (0..r.ch) |c| {
                const b = r.buf[c].items;
                var acc: f32 = 0;
                var j: usize = center + 1 - r.half;
                while (j <= center + r.half) : (j += 1) {
                    const d = @as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(center)) - frac;
                    acc += b[j] * r.kernel(d);
                }
                r.out[c][n] = acc * inv;
            }
            n += 1;
            r.pos += r.step;
            if (n == r.out[0].len) {
                enc.push(r.out[0][0..n], r.out[1][0..n]) catch return error.WriteFailed;
                n = 0;
            }
        }
        if (n > 0) enc.push(r.out[0][0..n], r.out[1][0..n]) catch return error.WriteFailed;
        // выбросить прочитанное, оставив историю ядра
        const keep_from: usize = @intFromFloat(@floor(r.pos));
        const drop = keep_from -| r.half;
        if (drop > 0) {
            for (0..r.ch) |c| {
                const b = &r.buf[c];
                std.mem.copyForwards(f32, b.items[0 .. b.items.len - drop], b.items[drop..]);
                b.shrinkRetainingCapacity(b.items.len - drop);
            }
            r.pos -= @floatFromInt(drop);
        }
    }
};

fn bessel0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 80) : (k += 1) {
        term *= (x / 2) * (x / 2) / (k * k);
        sum += term;
        if (term < sum * 1e-16) break;
    }
    return sum;
}

test {
    _ = mp3dec;
    _ = mp3enc;
    _ = vorbis;
    _ = aac;
    _ = mdct;
}

test "звук: пересчёт 22050 → 44100 сохраняет синус" {
    const a = std.testing.allocator;
    const Sink = struct {
        got: std.ArrayList(f32),
        fn push(k: *@This(), l: []const f32, r: []const f32) !void {
            _ = r;
            try k.got.appendSlice(l);
        }
    };
    var sink = Sink{ .got = std.ArrayList(f32).init(a) };
    defer sink.got.deinit();
    var rs = try Resampler.init(a, 22050, 44100, 1);
    defer rs.deinit();
    var x: [22050]f32 = undefined;
    for (0..x.len) |i| x[i] = 0.5 * @sin(2 * std.math.pi * 1000.0 * @as(f32, @floatFromInt(i)) / 22050.0);
    try rs.push(&x, &x, &sink);
    try rs.flush(&sink);
    const y = sink.got.items;
    try std.testing.expect(y.len >= 44090 and y.len <= 44110);
    // середина: сравнение с идеальным синусом на 44100 (задержки нет — ядро симметрично)
    var err: f64 = 0;
    var sig: f64 = 0;
    for (5000..40000) |i| {
        const ideal = 0.5 * @sin(2 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 44100.0);
        err += (y[i] - ideal) * (y[i] - ideal);
        sig += ideal * ideal;
    }
    try std.testing.expect(10 * std.math.log10(sig / err) > 60);
}

test "звук: тишина в MP3 и обратно" {
    const a = std.testing.allocator;
    // MP3 из синуса через кодер, затем всё через toMp3 (с пересчётом не нужно: 44100)
    var first = std.ArrayList(u8).init(a);
    defer first.deinit();
    var e = mp3enc.Encoder.init(first.writer().any(), 44100, 1);
    var buf: [1152]f32 = undefined;
    for (0..20) |f| {
        for (0..1152) |i| buf[i] = 0.3 * @sin(@as(f32, @floatFromInt(f * 1152 + i)) * 0.05);
        try e.push(&buf, &buf);
    }
    try e.finish();
    try std.testing.expectEqual(Kind.mp3, detect(first.items).?);
    var second = std.ArrayList(u8).init(a);
    defer second.deinit();
    const r = try toMp3(a, first.items, second.writer().any(), .{ .title = "t" });
    try std.testing.expectEqual(@as(u32, 44100), r.rate);
    try std.testing.expect(r.samples > 20 * 1152);
    try std.testing.expect(std.mem.eql(u8, second.items[second.items.len - 128 ..][0..3], "TAG"));
}
