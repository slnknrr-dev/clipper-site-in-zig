//! Обратное МДКП через БПФ (для Vorbis и AAC): N входных коэффициентов →
//! 2N отсчётов, y[n] = Σ X[k]·cos(π/N·(n + ½ + N/2)(k + ½)), без нормировки.
//! Внутри — DCT-IV размера N через комплексное БПФ размера N/2.

const std = @import("std");

pub const Imdct = struct {
    n: usize, // число коэффициентов (половина окна)
    tw_pre: []Cx,
    tw_post: []Cx,
    fft_tw: []Cx,
    rev: []u32,
    buf: []Cx,
    u: []f32,

    pub fn init(a: std.mem.Allocator, n: usize) !Imdct {
        std.debug.assert(n >= 4 and std.math.isPowerOfTwo(n));
        const h = n / 2;
        var m = Imdct{
            .n = n,
            .tw_pre = try a.alloc(Cx, h),
            .tw_post = try a.alloc(Cx, h),
            .fft_tw = try a.alloc(Cx, h / 2 + 1),
            .rev = try a.alloc(u32, h),
            .buf = try a.alloc(Cx, h),
            .u = try a.alloc(f32, n),
        };
        const fnn: f64 = @floatFromInt(n);
        for (0..h) |k| {
            const fk: f64 = @floatFromInt(k);
            const a0 = -std.math.pi * fk / fnn;
            const a1 = -std.math.pi * (fk + 0.25) / fnn;
            m.tw_pre[k] = .{ .re = @floatCast(@cos(a0)), .im = @floatCast(@sin(a0)) };
            m.tw_post[k] = .{ .re = @floatCast(@cos(a1)), .im = @floatCast(@sin(a1)) };
        }
        for (0..h / 2 + 1) |k| {
            const a2 = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(h));
            m.fft_tw[k] = .{ .re = @floatCast(@cos(a2)), .im = @floatCast(@sin(a2)) };
        }
        const bits = std.math.log2_int(usize, h);
        for (0..h) |i| m.rev[i] = if (bits == 0) 0 else @intCast(@bitReverse(@as(u32, @intCast(i))) >> @intCast(32 - @as(u6, bits)));
        return m;
    }

    pub fn deinit(m: *Imdct, a: std.mem.Allocator) void {
        a.free(m.tw_pre);
        a.free(m.tw_post);
        a.free(m.fft_tw);
        a.free(m.rev);
        a.free(m.buf);
        a.free(m.u);
    }

    /// DCT-IV: u[k] = Σ x[n]·cos(π/N·(n+½)(k+½)).
    fn dct4(m: *Imdct, x: []const f32) void {
        const n = m.n;
        const h = n / 2;
        const z = m.buf;
        for (0..h) |i| {
            const c = Cx{ .re = x[2 * i], .im = x[n - 1 - 2 * i] };
            z[m.rev[i]] = c.mul(m.tw_pre[i]);
        }
        // БПФ на месте (данные уже в обратном порядке битов)
        var len: usize = 2;
        while (len <= h) : (len <<= 1) {
            const step = h / len;
            var s: usize = 0;
            while (s < h) : (s += len) {
                for (0..len / 2) |j| {
                    const w = m.fft_tw[j * step];
                    const t = z[s + j + len / 2].mul(w);
                    const v = z[s + j];
                    z[s + j] = .{ .re = v.re + t.re, .im = v.im + t.im };
                    z[s + j + len / 2] = .{ .re = v.re - t.re, .im = v.im - t.im };
                }
            }
        }
        for (0..h) |k| {
            const c = z[k].mul(m.tw_post[k]);
            m.u[2 * k] = c.re;
            m.u[n - 1 - 2 * k] = -c.im;
        }
    }

    /// x: N коэффициентов → y: 2N отсчётов.
    pub fn run(m: *Imdct, x: []const f32, y: []f32) void {
        const n = m.n;
        m.dct4(x);
        const u = m.u;
        for (0..2 * n) |i| {
            const k = i + n / 2;
            y[i] = if (k < n) u[k] else if (k < 2 * n) -u[2 * n - 1 - k] else -u[k - 2 * n];
        }
    }
};

const Cx = struct {
    re: f32,
    im: f32,
    fn mul(a: Cx, b: Cx) Cx {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
};

test "ОМДКП через БПФ совпадает с прямой формулой" {
    const a = std.testing.allocator;
    for ([_]usize{ 4, 8, 64, 128, 1024 }) |n| {
        var m = try Imdct.init(a, n);
        defer m.deinit(a);
        const x = try a.alloc(f32, n);
        defer a.free(x);
        const y = try a.alloc(f32, 2 * n);
        defer a.free(y);
        var rng = std.Random.DefaultPrng.init(n);
        for (x) |*v| v.* = rng.random().float(f32) * 2 - 1;
        m.run(x, y);
        var err: f64 = 0;
        for (0..2 * n) |i| {
            var acc: f64 = 0;
            for (0..n) |k| acc += x[k] * @cos(std.math.pi / @as(f64, @floatFromInt(n)) * (@as(f64, @floatFromInt(i)) + 0.5 + @as(f64, @floatFromInt(n)) / 2) * (@as(f64, @floatFromInt(k)) + 0.5));
            err = @max(err, @abs(acc - y[i]));
        }
        try std.testing.expect(err < 1e-3 * @as(f64, @floatFromInt(n)) / 64 + 1e-4);
    }
}
