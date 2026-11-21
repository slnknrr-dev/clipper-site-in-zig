//! Обучение словаря zstd («сырое содержимое») на корпусе текстов одного языка.
//!
//! Способ — упрощённый COVER (Liao и др., 2016; так обучает словари и сам zstd):
//! корпус делится на эпохи по числу будущих фрагментов; в каждой эпохе
//! выбирается фрагмент, в котором больше всего частых и ещё не взятых k-грамм;
//! взятые k-граммы обнуляются, чтобы словарь не повторялся. Самые ценные
//! фрагменты ставятся в конец словаря: так их смещения от сжимаемых данных
//! короче и дешевле.

const std = @import("std");

pub const Params = struct {
    /// размер словаря
    size: usize = 64 * 1024,
    /// длина фрагмента
    segment: usize = 256,
    /// длина k-граммы
    k: usize = 8,
};

const table_log = 20;

fn hashAt(s: []const u8, i: usize, k: usize) u32 {
    var h: u32 = 2166136261;
    for (s[i..][0..k]) |b| h = (h ^ b) *% 16777619;
    return h >> (32 - table_log);
}

/// Словарь из корпуса. Корпус меньше словаря — словарём становится сам корпус.
pub fn train(a: std.mem.Allocator, corpus: []const u8, p: Params) ![]u8 {
    if (corpus.len <= p.size) return a.dupe(u8, corpus);
    if (p.k == 0 or p.segment < p.k) return error.BadParams;
    const freq = try a.alloc(u32, 1 << table_log);
    defer a.free(freq);
    @memset(freq, 0);
    var i: usize = 0;
    while (i + p.k <= corpus.len) : (i += 1) {
        const h = hashAt(corpus, i, p.k);
        freq[h] +|= 1;
    }
    const nseg = p.size / p.segment;
    const epoch = corpus.len / nseg;
    const Pick = struct { at: usize, score: u64 };
    var picks = try a.alloc(Pick, nseg);
    defer a.free(picks);
    var n: usize = 0;
    var e: usize = 0;
    while (e < nseg) : (e += 1) {
        const from = e * epoch;
        const to = @min(corpus.len, from + epoch);
        if (to < from + p.segment) continue;
        // скользящая сумма частот k-грамм окна длиной segment
        const span = p.segment - p.k + 1;
        var sum: u64 = 0;
        var j: usize = from;
        while (j < from + span) : (j += 1) sum += freq[hashAt(corpus, j, p.k)];
        var best: u64 = sum;
        var best_at: usize = from;
        var s = from;
        while (s + p.segment < to) : (s += 1) {
            sum -= freq[hashAt(corpus, s, p.k)];
            sum += freq[hashAt(corpus, s + span, p.k)];
            if (sum > best) {
                best = sum;
                best_at = s + 1;
            }
        }
        if (best == 0) continue;
        picks[n] = .{ .at = best_at, .score = best };
        n += 1;
        // взятое больше не в цене
        var q = best_at;
        while (q < best_at + span) : (q += 1) freq[hashAt(corpus, q, p.k)] = 0;
    }
    std.mem.sort(Pick, picks[0..n], {}, struct {
        fn lt(_: void, x: Pick, y: Pick) bool {
            return x.score < y.score;
        }
    }.lt);
    const out = try a.alloc(u8, n * p.segment);
    for (picks[0..n], 0..) |pk, k| @memcpy(out[k * p.segment ..][0..p.segment], corpus[pk.at..][0..p.segment]);
    return out;
}

test "словарь: из повторяющегося корпуса берутся частые фрагменты" {
    const a = std.testing.allocator;
    var corpus = std.ArrayList(u8).init(a);
    defer corpus.deinit();
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    const words = [_][]const u8{ "князь ", "Андрей ", "сказал ", "Наташа ", "война ", "мир ", "и ", "в ", "не ", "что " };
    while (corpus.items.len < 200_000) try corpus.appendSlice(words[r.uintLessThan(usize, words.len)]);
    const d = try train(a, corpus.items, .{ .size = 4096, .segment = 128, .k = 6 });
    defer a.free(d);
    try std.testing.expect(d.len > 2048 and d.len <= 4096);
    try std.testing.expect(std.mem.indexOf(u8, d, "князь") != null);
}
