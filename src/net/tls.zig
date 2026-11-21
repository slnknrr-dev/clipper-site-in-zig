//! Свой сервер TLS 1.3 (RFC 8446) на примитивах std: в std 0.14.1 есть только
//! клиент. Обмен ключами — X25519, шифры — AES-128-GCM и ChaCha20-Poly1305,
//! HKDF-SHA256, подпись CertificateVerify — ECDSA P-256 или Ed25519.
//!
//! Только TLS 1.3; без возобновления сеансов и 0-RTT; ALPN `http/1.1`.
//! Ключи RSA не поддерживаются (в std нет RSA-подписи): с таким ключом сервер
//! не стартует и говорит об этом.
//!
//! Сеанс не знает о сокетах больше, чем «прочитать» и «послать»: ядро
//! (`feed`, `seal`) работает над байтами, поэтому проверяется в памяти
//! клиентом `std.crypto.tls.Client`.

const std = @import("std");
const t9n = @import("../t9n.zig");
const net = @import("net.zig");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const Hmac = crypto.auth.hmac.sha2.HmacSha256;
const Hkdf = crypto.kdf.hkdf.HkdfSha256;
const X25519 = crypto.dh.X25519;
const Aes = crypto.aead.aes_gcm.Aes128Gcm;
const Chacha = crypto.aead.chacha_poly.ChaCha20Poly1305;
const P256 = crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed = crypto.sign.Ed25519;

const max_plain = 16384;
const max_record = max_plain + 256;
/// Сколько открытого текста кладём в одну запись при отправке.
const chunk = 16000;

// ───────────── ключ и сертификат ─────────────

const Key = union(enum) { p256: P256.KeyPair, ed25519: Ed.KeyPair };

pub const Config = struct {
    key: Key,
    /// Готовое сообщение Certificate (с заголовком рукопожатия).
    cert_msg: []const u8,

    fn scheme(c: *const Config) u16 {
        return switch (c.key) {
            .p256 => 0x0403, // ecdsa_secp256r1_sha256
            .ed25519 => 0x0807,
        };
    }

    /// Читает PEM-файлы. Ошибка — понятная строка в `msg`.
    pub fn load(gpa: std.mem.Allocator, cert_path: []const u8, key_path: []const u8, msg: *[]const u8) !*const Config {
        const cert_pem = std.fs.cwd().readFileAlloc(gpa, cert_path, 1 << 20) catch {
            msg.* = t9n.tr("--tls-cert: файл сертификата не читается");
            return error.BadTls;
        };
        const key_pem = std.fs.cwd().readFileAlloc(gpa, key_path, 1 << 20) catch {
            msg.* = t9n.tr("--tls-key: файл ключа не читается");
            return error.BadTls;
        };
        return fromPem(gpa, cert_pem, key_pem, msg);
    }

    pub fn fromPem(gpa: std.mem.Allocator, cert_pem: []const u8, key_pem: []const u8, msg: *[]const u8) !*const Config {
        // цепочка сертификатов: первый — сервера
        var certs = std.ArrayList([]const u8).init(gpa);
        var rest = cert_pem;
        while (pemBlock(gpa, &rest, "CERTIFICATE") catch {
            msg.* = t9n.tr("--tls-cert: сертификат повреждён (ожидается PEM)");
            return error.BadTls;
        }) |der_bytes| try certs.append(der_bytes);
        if (certs.items.len == 0) {
            msg.* = t9n.tr("--tls-cert: в файле нет сертификата (-----BEGIN CERTIFICATE-----)");
            return error.BadTls;
        }
        var list = std.ArrayList(u8).init(gpa);
        for (certs.items) |c| {
            try list.appendSlice(&u24be(c.len));
            try list.appendSlice(c);
            try list.appendSlice(&.{ 0, 0 }); // без расширений
        }
        if (list.items.len > 20000) {
            msg.* = t9n.tr("--tls-cert: цепочка сертификатов слишком длинная");
            return error.BadTls;
        }
        var cm = std.ArrayList(u8).init(gpa);
        try cm.append(11);
        try cm.appendSlice(&u24be(list.items.len + 4));
        try cm.append(0); // certificate_request_context
        try cm.appendSlice(&u24be(list.items.len));
        try cm.appendSlice(list.items);

        const key = parseKey(gpa, key_pem, msg) catch |err| {
            if (msg.len == 0) msg.* = t9n.tr("--tls-key: ключ не разобран (нужен PEM: ECDSA P-256 или Ed25519)");
            return err;
        };
        // Ключ должен подходить к сертификату: его открытая часть есть в сертификате.
        var pub_buf: [65]u8 = undefined;
        const public: []const u8 = switch (key) {
            .p256 => |kp| blk: {
                pub_buf = kp.public_key.toUncompressedSec1();
                break :blk pub_buf[0..65];
            },
            .ed25519 => |kp| blk: {
                pub_buf[0..32].* = kp.public_key.toBytes();
                break :blk pub_buf[0..32];
            },
        };
        if (std.mem.indexOf(u8, certs.items[0], public) == null) {
            msg.* = t9n.tr("--tls-key: ключ не подходит к сертификату");
            return error.BadTls;
        }
        const cfg = try gpa.create(Config);
        cfg.* = .{ .key = key, .cert_msg = cm.items };
        return cfg;
    }
};

fn u24be(n: usize) [3]u8 {
    return .{ @intCast((n >> 16) & 0xff), @intCast((n >> 8) & 0xff), @intCast(n & 0xff) };
}

/// Следующий блок PEM с меткой `label` из `rest`; null — больше нет.
fn pemBlock(gpa: std.mem.Allocator, rest: *[]const u8, comptime label: []const u8) !?[]u8 {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    const b = std.mem.indexOf(u8, rest.*, begin) orelse return null;
    const e = std.mem.indexOfPos(u8, rest.*, b, end) orelse return error.BadPem;
    const body = rest.*[b + begin.len .. e];
    rest.* = rest.*[e + end.len ..];
    const dec = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const out = try gpa.alloc(u8, body.len);
    const n = dec.decode(out, body) catch return error.BadPem;
    return out[0..n];
}

const Tlv = struct { tag: u8, body: []const u8, rest: []const u8 };

fn tlv(bytes: []const u8) !Tlv {
    if (bytes.len < 2) return error.BadDer;
    var len: usize = bytes[1];
    var at: usize = 2;
    if (len & 0x80 != 0) {
        const n = len & 0x7f;
        if (n == 0 or n > 3 or bytes.len < 2 + n) return error.BadDer;
        len = 0;
        for (bytes[2 .. 2 + n]) |b| len = (len << 8) | b;
        at = 2 + n;
    }
    if (bytes.len - at < len) return error.BadDer;
    return .{ .tag = bytes[0], .body = bytes[at .. at + len], .rest = bytes[at + len ..] };
}

const oid_ec = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
const oid_ed25519 = [_]u8{ 0x2B, 0x65, 0x70 };
const oid_rsa = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };

/// ECPrivateKey (SEC1): SEQUENCE { INTEGER 1, OCTET STRING ключ, … }
fn sec1Key(der_bytes: []const u8, need_curve: bool, msg: *[]const u8) !Key {
    const seq = try tlv(der_bytes);
    if (seq.tag != 0x30) return error.BadDer;
    const ver = try tlv(seq.body);
    const oct = try tlv(ver.rest);
    if (oct.tag != 0x04 or oct.body.len != 32) {
        msg.* = t9n.tr("--tls-key: поддерживается только кривая P-256 (prime256v1)");
        return error.BadTls;
    }
    if (need_curve) {
        // [0] параметры: OID кривой
        if (std.mem.indexOf(u8, oct.rest, &oid_p256) == null) {
            msg.* = t9n.tr("--tls-key: поддерживается только кривая P-256 (prime256v1)");
            return error.BadTls;
        }
    }
    const sk = P256.SecretKey.fromBytes(oct.body[0..32].*) catch return error.BadDer;
    return .{ .p256 = P256.KeyPair.fromSecretKey(sk) catch return error.BadDer };
}

fn parseKey(gpa: std.mem.Allocator, pem: []const u8, msg: *[]const u8) !Key {
    var rest = pem;
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") != null) {
        msg.* = t9n.tr("--tls-key: ключи RSA не поддерживаются (нужен ECDSA P-256 или Ed25519)");
        return error.BadTls;
    }
    if (std.mem.indexOf(u8, pem, "BEGIN ENCRYPTED PRIVATE KEY") != null) {
        msg.* = t9n.tr("--tls-key: ключ зашифрован паролем; нужен незашифрованный");
        return error.BadTls;
    }
    if (try pemBlock(gpa, &rest, "EC PRIVATE KEY")) |d| return sec1Key(d, true, msg);
    rest = pem;
    const d = (try pemBlock(gpa, &rest, "PRIVATE KEY")) orelse return error.BadTls;
    // PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { OID, параметры }, OCTET STRING ключ }
    const seq = try tlv(d);
    const ver = try tlv(seq.body);
    const alg = try tlv(ver.rest);
    const oct = try tlv(alg.rest);
    if (seq.tag != 0x30 or alg.tag != 0x30 or oct.tag != 0x04) return error.BadDer;
    const oid = try tlv(alg.body);
    if (std.mem.eql(u8, oid.body, &oid_rsa)) {
        msg.* = t9n.tr("--tls-key: ключи RSA не поддерживаются (нужен ECDSA P-256 или Ed25519)");
        return error.BadTls;
    }
    if (std.mem.eql(u8, oid.body, &oid_ed25519)) {
        const inner = try tlv(oct.body);
        if (inner.tag != 0x04 or inner.body.len != 32) return error.BadDer;
        return .{ .ed25519 = Ed.KeyPair.generateDeterministic(inner.body[0..32].*) catch return error.BadDer };
    }
    if (std.mem.eql(u8, oid.body, &oid_ec)) {
        const curve = try tlv(oid.rest);
        if (!std.mem.eql(u8, curve.body, &oid_p256)) {
            msg.* = t9n.tr("--tls-key: поддерживается только кривая P-256 (prime256v1)");
            return error.BadTls;
        }
        return sec1Key(oct.body, false, msg);
    }
    msg.* = t9n.tr("--tls-key: неизвестный вид ключа (нужен ECDSA P-256 или Ed25519)");
    return error.BadTls;
}

// ───────────── расписание ключей ─────────────

fn expandLabel(secret: [32]u8, comptime label: []const u8, context: []const u8, comptime len: usize) [len]u8 {
    var info: [2 + 1 + 6 + 32 + 1 + 32]u8 = undefined;
    const full = "tls13 " ++ label;
    info[0] = @intCast(len >> 8);
    info[1] = @intCast(len & 0xff);
    info[2] = full.len;
    @memcpy(info[3..][0..full.len], full);
    info[3 + full.len] = @intCast(context.len);
    @memcpy(info[4 + full.len ..][0..context.len], context);
    var out: [len]u8 = undefined;
    Hkdf.expand(&out, info[0 .. 4 + full.len + context.len], secret);
    return out;
}

const Suite = enum { aes128, chacha };

const Keys = struct {
    secret: [32]u8 = undefined,
    key: [32]u8 = undefined,
    iv: [12]u8 = undefined,
    seq: u64 = 0,

    fn derive(suite: Suite, secret: [32]u8) Keys {
        var k = Keys{ .secret = secret };
        switch (suite) {
            .aes128 => k.key[0..16].* = expandLabel(secret, "key", "", 16),
            .chacha => k.key = expandLabel(secret, "key", "", 32),
        }
        k.iv = expandLabel(secret, "iv", "", 12);
        return k;
    }

    fn nonce(k: *Keys) [12]u8 {
        var n = k.iv;
        var s: [8]u8 = undefined;
        std.mem.writeInt(u64, &s, k.seq, .big);
        for (n[4..], s) |*x, y| x.* ^= y;
        k.seq += 1;
        return n;
    }
};

/// Шифрует запись: `inner` и его тип — в запись вида application_data.
/// Возвращает длину записи в `out`.
fn seal(suite: Suite, k: *Keys, kind: u8, inner: []const u8, out: []u8) usize {
    const n = inner.len + 1;
    out[0] = 23;
    out[1] = 3;
    out[2] = 3;
    std.mem.writeInt(u16, out[3..5], @intCast(n + 16), .big);
    var plain: [max_plain + 1]u8 = undefined;
    @memcpy(plain[0..inner.len], inner);
    plain[inner.len] = kind;
    var tag: [16]u8 = undefined;
    const npub = k.nonce();
    switch (suite) {
        .aes128 => Aes.encrypt(out[5..][0..n], &tag, plain[0..n], out[0..5], npub, k.key[0..16].*),
        .chacha => Chacha.encrypt(out[5..][0..n], &tag, plain[0..n], out[0..5], npub, k.key),
    }
    @memcpy(out[5 + n ..][0..16], &tag);
    return 5 + n + 16;
}

/// Расшифровывает тело записи; возвращает содержимое и его тип.
fn open(suite: Suite, k: *Keys, header: *const [5]u8, body: []const u8, out: []u8) !struct { []u8, u8 } {
    if (body.len < 17 or body.len - 16 > out.len) return error.BadRecord;
    const n = body.len - 16;
    const npub = k.nonce();
    switch (suite) {
        .aes128 => Aes.decrypt(out[0..n], body[0..n], body[n..][0..16].*, header, npub, k.key[0..16].*) catch return error.BadRecord,
        .chacha => Chacha.decrypt(out[0..n], body[0..n], body[n..][0..16].*, header, npub, k.key) catch return error.BadRecord,
    }
    var end = n;
    while (end > 0 and out[end - 1] == 0) end -= 1; // дополнение нулями
    if (end == 0) return error.BadRecord;
    return .{ out[0 .. end - 1], out[end - 1] };
}

// ───────────── ClientHello ─────────────

const Hello = struct {
    session_id: []const u8 = "",
    tls13: bool = false,
    aes: bool = false,
    chacha: bool = false,
    share: ?[32]u8 = null,
    group_x25519: bool = false,
    sig_ok: bool = false,
    alpn_http11: bool = false,
};

const Reader = struct {
    b: []const u8,
    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.b.len < n) return error.BadHello;
        const out = r.b[0..n];
        r.b = r.b[n..];
        return out;
    }
    fn int(r: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }
    fn vec(r: *Reader, comptime L: type) ![]const u8 {
        return r.take(try r.int(L));
    }
};

fn parseHello(body: []const u8, scheme: u16) !Hello {
    var h = Hello{};
    var r = Reader{ .b = body };
    _ = try r.take(2 + 32); // версия, случайное
    h.session_id = try r.vec(u8);
    if (h.session_id.len > 32) return error.BadHello;
    var suites = Reader{ .b = try r.vec(u16) };
    while (suites.b.len >= 2) switch (try suites.int(u16)) {
        0x1301 => h.aes = true,
        0x1303 => h.chacha = true,
        else => {},
    };
    _ = try r.vec(u8); // сжатие
    if (r.b.len == 0) return h;
    var exts = Reader{ .b = try r.vec(u16) };
    while (exts.b.len > 0) {
        const kind = try exts.int(u16);
        var e = Reader{ .b = try exts.vec(u16) };
        switch (kind) {
            43 => { // supported_versions
                var v = Reader{ .b = try e.vec(u8) };
                while (v.b.len >= 2) if (try v.int(u16) == 0x0304) {
                    h.tls13 = true;
                };
            },
            10 => { // supported_groups
                var g = Reader{ .b = try e.vec(u16) };
                while (g.b.len >= 2) if (try g.int(u16) == 0x001d) {
                    h.group_x25519 = true;
                };
            },
            51 => { // key_share
                var ks = Reader{ .b = try e.vec(u16) };
                while (ks.b.len > 0) {
                    const group = try ks.int(u16);
                    const key = try ks.vec(u16);
                    if (group == 0x001d and key.len == 32 and h.share == null) h.share = key[0..32].*;
                }
            },
            13 => { // signature_algorithms
                var s = Reader{ .b = try e.vec(u16) };
                while (s.b.len >= 2) if (try s.int(u16) == scheme) {
                    h.sig_ok = true;
                };
            },
            16 => { // ALPN
                var a = Reader{ .b = try e.vec(u16) };
                while (a.b.len > 0) if (std.mem.eql(u8, try a.vec(u8), "http/1.1")) {
                    h.alpn_http11 = true;
                };
            },
            else => {},
        }
    }
    return h;
}

// ───────────── сеанс ─────────────

const hrr_random = [32]u8{ 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91, 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C };

pub const Session = struct {
    cfg: *const Config,
    state: enum { hello, wait_finished, app, closed } = .hello,
    suite: Suite = .aes128,
    transcript: Sha256 = Sha256.init(.{}),
    hrr_sent: bool = false,
    client_hs: Keys = .{},
    server_hs: Keys = .{},
    client_ap: Keys = .{},
    server_ap: Keys = .{},
    master: [32]u8 = undefined,
    in: [5 + max_record + 64]u8 = undefined,
    in_len: usize = 0,
    /// сообщения рукопожатия, собранные из записей
    hs: [8192]u8 = undefined,
    hs_len: usize = 0,
    plain: [max_plain + 64]u8 = undefined,
    plain_at: usize = 0,
    plain_len: usize = 0,
    out: [48 * 1024]u8 = undefined,
    out_at: usize = 0,
    out_len: usize = 0,

    pub fn create(gpa: std.mem.Allocator, cfg: *const Config) !*Session {
        const s = try gpa.create(Session);
        s.* = .{ .cfg = cfg };
        return s;
    }

    pub fn destroy(s: *Session, gpa: std.mem.Allocator) void {
        crypto.secureZero(u8, std.mem.asBytes(&s.client_ap));
        crypto.secureZero(u8, std.mem.asBytes(&s.server_ap));
        gpa.destroy(s);
    }

    pub fn pending(s: *const Session) usize {
        return s.out_len - s.out_at;
    }

    fn room(s: *Session, n: usize) ![]u8 {
        if (s.out_at == s.out_len) {
            s.out_at = 0;
            s.out_len = 0;
        }
        if (s.out.len - s.out_len < n) return error.Overflow;
        return s.out[s.out_len..];
    }

    fn putPlainRecord(s: *Session, kind: u8, body: []const u8) !void {
        const o = try s.room(5 + body.len);
        o[0] = kind;
        o[1] = 3;
        o[2] = 3;
        std.mem.writeInt(u16, o[3..5], @intCast(body.len), .big);
        @memcpy(o[5..][0..body.len], body);
        s.out_len += 5 + body.len;
    }

    fn putSealed(s: *Session, k: *Keys, kind: u8, body: []const u8) !void {
        var at: usize = 0;
        while (true) {
            const n = @min(chunk, body.len - at);
            const o = try s.room(5 + n + 17);
            s.out_len += seal(s.suite, k, kind, body[at..][0..n], o);
            at += n;
            if (at >= body.len) break;
        }
    }

    fn alert(s: *Session, desc: u8) void {
        const body = [2]u8{ 2, desc };
        switch (s.state) {
            .hello => s.putPlainRecord(21, &body) catch {},
            .wait_finished => s.putSealed(&s.server_hs, 21, &body) catch {},
            .app => s.putSealed(&s.server_ap, 21, &body) catch {},
            .closed => {},
        }
        s.state = .closed;
    }

    /// Оповещение о закрытии (close_notify), если сеанс установлен.
    pub fn shutdown(s: *Session, fd: net.Socket) void {
        if (s.state != .app) return;
        s.putSealed(&s.server_ap, 21, &.{ 1, 0 }) catch return;
        s.state = .closed;
        s.flush(fd) catch {};
    }

    fn hashNow(s: *const Session) [32]u8 {
        var h = s.transcript;
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    // ───── вход ─────

    /// Принимает байты от клиента и разбирает все полные записи.
    /// Расшифрованные данные ложатся в `plain`, ответы рукопожатия — в `out`.
    pub fn feed(s: *Session, bytes: []const u8) !void {
        if (bytes.len > s.in.len - s.in_len) return error.BadRecord;
        @memcpy(s.in[s.in_len..][0..bytes.len], bytes);
        s.in_len += bytes.len;
        try s.step();
    }

    fn step(s: *Session) !void {
        while (s.in_len >= 5 and s.state != .closed) {
            // Данные приложения разбираются по одной записи: пока прежние не забрали.
            if (s.plain_at < s.plain_len) return;
            const len: usize = std.mem.readInt(u16, s.in[3..5], .big);
            if (len > max_record) {
                s.alert(22); // record_overflow
                return error.BadRecord;
            }
            if (s.in_len < 5 + len) return;
            s.record(s.in[0], s.in[0..5], s.in[5 .. 5 + len]) catch |err| {
                if (s.state != .closed) s.alert(switch (err) {
                    error.BadRecord => 20, // bad_record_mac
                    error.NoCommon => 40, // handshake_failure
                    error.Version => 70, // protocol_version
                    error.BadFinished => 51, // decrypt_error
                    else => 50, // decode_error
                });
                return err;
            };
            const used = 5 + len;
            std.mem.copyForwards(u8, s.in[0 .. s.in_len - used], s.in[used..s.in_len]);
            s.in_len -= used;
        }
    }

    fn record(s: *Session, kind: u8, header: *const [5]u8, body: []const u8) !void {
        switch (s.state) {
            .hello => {
                if (kind == 20) return; // ChangeCipherSpec совместимости
                if (kind != 22) return error.Unexpected;
                try s.gather(body);
                while (try s.message()) |m| {
                    if (m[0] != 1) return error.Unexpected;
                    try s.clientHello(m);
                    s.consume(m.len);
                    if (s.state != .hello) break;
                }
            },
            .wait_finished => {
                if (kind == 20) return;
                if (kind != 23) return error.Unexpected;
                var buf: [max_record]u8 = undefined;
                const inner, const t = try open(s.suite, &s.client_hs, header, body, &buf);
                if (t == 21) {
                    s.state = .closed;
                    return;
                }
                if (t != 22) return error.Unexpected;
                try s.gather(inner);
                while (try s.message()) |m| {
                    if (m[0] != 20 or m.len != 4 + 32) return error.Unexpected;
                    const fin_key = expandLabel(s.client_hs.secret, "finished", "", 32);
                    var want: [32]u8 = undefined;
                    Hmac.create(&want, &s.hashNow(), &fin_key);
                    if (!crypto.timing_safe.eql([32]u8, want, m[4..36].*)) return error.BadFinished;
                    s.consume(m.len);
                    s.state = .app;
                    break;
                }
            },
            .app => {
                if (kind != 23) return error.Unexpected;
                const inner, const t = try open(s.suite, &s.client_ap, header, body, &s.plain);
                switch (t) {
                    23 => {
                        s.plain_at = 0;
                        s.plain_len = inner.len;
                    },
                    21 => s.state = .closed, // close_notify или ошибка клиента
                    22 => {
                        // после рукопожатия допустимо только KeyUpdate
                        if (inner.len != 5 or inner[0] != 24) return error.Unexpected;
                        s.client_ap = Keys.derive(s.suite, expandLabel(s.client_ap.secret, "traffic upd", "", 32));
                        if (inner[4] == 1) {
                            try s.putSealed(&s.server_ap, 22, &.{ 24, 0, 0, 1, 0 });
                            s.server_ap = Keys.derive(s.suite, expandLabel(s.server_ap.secret, "traffic upd", "", 32));
                        }
                    },
                    else => return error.Unexpected,
                }
            },
            .closed => {},
        }
    }

    fn gather(s: *Session, bytes: []const u8) !void {
        if (bytes.len > s.hs.len - s.hs_len) return error.Overflow;
        @memcpy(s.hs[s.hs_len..][0..bytes.len], bytes);
        s.hs_len += bytes.len;
    }

    /// Полное сообщение рукопожатия из собранного, с заголовком; null — ещё не всё.
    fn message(s: *Session) !?[]const u8 {
        if (s.hs_len < 4) return null;
        const len: usize = (@as(usize, s.hs[1]) << 16) | (@as(usize, s.hs[2]) << 8) | s.hs[3];
        if (4 + len > s.hs.len) return error.Overflow;
        if (s.hs_len < 4 + len) return null;
        return s.hs[0 .. 4 + len];
    }

    fn consume(s: *Session, n: usize) void {
        std.mem.copyForwards(u8, s.hs[0 .. s.hs_len - n], s.hs[n..s.hs_len]);
        s.hs_len -= n;
    }

    fn clientHello(s: *Session, m: []const u8) !void {
        const h = try parseHello(m[4..], s.cfg.scheme());
        if (!h.tls13) return error.Version;
        if (!h.sig_ok or (!h.aes and !h.chacha)) return error.NoCommon;
        s.suite = if (h.aes) .aes128 else .chacha;
        const suite_id: u16 = if (h.aes) 0x1301 else 0x1303;

        const share = h.share orelse {
            // Клиент не прислал ключ X25519: один раз просим повторить.
            if (s.hrr_sent or !h.group_x25519) return error.NoCommon;
            s.hrr_sent = true;
            var first: [32]u8 = undefined;
            Sha256.hash(m, &first, .{});
            s.transcript = Sha256.init(.{});
            s.transcript.update(&.{ 254, 0, 0, 32 }); // message_hash
            s.transcript.update(&first);
            var sh: [128]u8 = undefined;
            const n = serverHello(&sh, hrr_random, h.session_id, suite_id, null);
            s.transcript.update(sh[0..n]);
            try s.putPlainRecord(22, sh[0..n]);
            try s.putPlainRecord(20, &.{1});
            return;
        };

        s.transcript.update(m);
        const kp = X25519.KeyPair.generate();
        const shared = X25519.scalarmult(kp.secret_key, share) catch return error.NoCommon;
        var random: [32]u8 = undefined;
        crypto.random.bytes(&random);
        var sh: [128]u8 = undefined;
        const sh_n = serverHello(&sh, random, h.session_id, suite_id, kp.public_key);
        s.transcript.update(sh[0..sh_n]);
        try s.putPlainRecord(22, sh[0..sh_n]);
        if (!s.hrr_sent) try s.putPlainRecord(20, &.{1});

        // ключи рукопожатия
        const zeros = [_]u8{0} ** 32;
        var empty_hash: [32]u8 = undefined;
        Sha256.hash("", &empty_hash, .{});
        const early = Hkdf.extract(&zeros, &zeros);
        const hs_secret = Hkdf.extract(&expandLabel(early, "derived", &empty_hash, 32), &shared);
        const th = s.hashNow();
        s.client_hs = Keys.derive(s.suite, expandLabel(hs_secret, "c hs traffic", &th, 32));
        s.server_hs = Keys.derive(s.suite, expandLabel(hs_secret, "s hs traffic", &th, 32));
        s.master = Hkdf.extract(&expandLabel(hs_secret, "derived", &empty_hash, 32), &zeros);

        // EncryptedExtensions, Certificate, CertificateVerify, Finished — одним полётом
        var flight = std.BoundedArray(u8, 24 * 1024){};
        const ee: []const u8 = if (h.alpn_http11)
            &[_]u8{ 8, 0, 0, 17, 0, 15, 0, 16, 0, 11, 0, 9, 8, 'h', 't', 't', 'p', '/', '1', '.', '1' }
        else
            &[_]u8{ 8, 0, 0, 2, 0, 0 };
        flight.appendSlice(ee) catch return error.Overflow;
        s.transcript.update(ee);
        flight.appendSlice(s.cfg.cert_msg) catch return error.Overflow;
        s.transcript.update(s.cfg.cert_msg);

        var signed: [64 + 33 + 1 + 32]u8 = undefined;
        @memset(signed[0..64], 0x20);
        @memcpy(signed[64..97], "TLS 1.3, server CertificateVerify");
        signed[97] = 0;
        signed[98..130].* = s.hashNow();
        var sig_buf: [P256.Signature.der_encoded_length_max]u8 = undefined;
        var ed_sig: [64]u8 = undefined;
        const sig: []const u8 = switch (s.cfg.key) {
            .p256 => |k| (k.sign(&signed, null) catch return error.NoCommon).toDer(&sig_buf),
            .ed25519 => |k| blk: {
                ed_sig = (k.sign(&signed, null) catch return error.NoCommon).toBytes();
                break :blk &ed_sig;
            },
        };
        var cv = std.BoundedArray(u8, 128){};
        cv.appendSlice(&.{ 15, 0, 0, @intCast(4 + sig.len), @intCast(s.cfg.scheme() >> 8), @intCast(s.cfg.scheme() & 0xff), 0, @intCast(sig.len) }) catch unreachable;
        cv.appendSlice(sig) catch unreachable;
        flight.appendSlice(cv.slice()) catch return error.Overflow;
        s.transcript.update(cv.slice());

        var fin = [_]u8{ 20, 0, 0, 32 } ++ [_]u8{0} ** 32;
        const fin_key = expandLabel(s.server_hs.secret, "finished", "", 32);
        Hmac.create(fin[4..36], &s.hashNow(), &fin_key);
        flight.appendSlice(&fin) catch return error.Overflow;
        s.transcript.update(&fin);
        try s.putSealed(&s.server_hs, 22, flight.slice());

        // ключи приложения — по стенограмме до Finished сервера включительно
        const th_ap = s.hashNow();
        s.client_ap = Keys.derive(s.suite, expandLabel(s.master, "c ap traffic", &th_ap, 32));
        s.server_ap = Keys.derive(s.suite, expandLabel(s.master, "s ap traffic", &th_ap, 32));
        // Finished клиента проверяется по той же стенограмме
        s.state = .wait_finished;
    }

    // ───── выход ─────

    /// Шифрует данные приложения в очередь отправки; сколько взято.
    pub fn sealApp(s: *Session, bytes: []const u8) !usize {
        if (s.state != .app) return error.NotReady;
        const n = @min(bytes.len, chunk);
        const o = try s.room(5 + n + 17);
        s.out_len += seal(s.suite, &s.server_ap, 23, bytes[0..n], o);
        return n;
    }

    /// Забирает расшифрованные данные приложения.
    pub fn takePlain(s: *Session, buf: []u8) usize {
        const n = @min(buf.len, s.plain_len - s.plain_at);
        @memcpy(buf[0..n], s.plain[s.plain_at..][0..n]);
        s.plain_at += n;
        return n;
    }

    // ───── над сокетом ─────

    pub fn flush(s: *Session, fd: net.Socket) net.WriteError!void {
        while (s.out_at < s.out_len) {
            s.out_at += try net.send(fd, s.out[s.out_at..s.out_len]);
        }
    }

    /// Как `net.read`: расшифрованные байты запроса; 0 — клиент закрыл соединение.
    pub fn read(s: *Session, fd: net.Socket, buf: []u8) net.ReadError!usize {
        while (true) {
            const n = s.takePlain(buf);
            if (n > 0) return n;
            if (s.state == .closed) return 0;
            // сначала — то, что уже лежит во входном буфере
            const before = s.in_len;
            s.step() catch {
                s.flush(fd) catch {};
                return error.Failed;
            };
            if (s.plain_at < s.plain_len) continue;
            if (s.pending() > 0) s.flush(fd) catch |err| switch (err) {
                error.WouldBlock => {},
                error.Broken => return error.Failed,
            };
            if (s.in_len != before) continue;
            var tmp: [8192]u8 = undefined;
            const want = @min(tmp.len, s.in.len - s.in_len);
            if (want == 0) return error.Failed;
            const got = try net.read(fd, tmp[0..want]);
            if (got == 0) return 0;
            @memcpy(s.in[s.in_len..][0..got], tmp[0..got]);
            s.in_len += got;
        }
    }

    /// Как `net.send`: сколько байт ответа взято в шифрование.
    pub fn write(s: *Session, fd: net.Socket, bytes: []const u8) net.WriteError!usize {
        try s.flush(fd);
        const n = s.sealApp(bytes) catch return error.Broken;
        s.flush(fd) catch |err| switch (err) {
            error.WouldBlock => {}, // зашифрованное дошлётся позже
            error.Broken => return error.Broken,
        };
        return n;
    }
};

/// ServerHello (или HelloRetryRequest, если `public` = null) с заголовком рукопожатия.
fn serverHello(out: *[128]u8, random: [32]u8, session_id: []const u8, suite: u16, public: ?[32]u8) usize {
    var n: usize = 4;
    out[n] = 3;
    out[n + 1] = 3;
    n += 2;
    @memcpy(out[n..][0..32], &random);
    n += 32;
    out[n] = @intCast(session_id.len);
    n += 1;
    @memcpy(out[n..][0..session_id.len], session_id);
    n += session_id.len;
    std.mem.writeInt(u16, out[n..][0..2], suite, .big);
    out[n + 2] = 0; // без сжатия
    n += 3;
    const ext_at = n;
    n += 2;
    // supported_versions: TLS 1.3
    @memcpy(out[n..][0..6], &[_]u8{ 0, 43, 0, 2, 3, 4 });
    n += 6;
    if (public) |p| {
        @memcpy(out[n..][0..8], &[_]u8{ 0, 51, 0, 36, 0, 0x1d, 0, 32 });
        n += 8;
        @memcpy(out[n..][0..32], &p);
        n += 32;
    } else {
        @memcpy(out[n..][0..6], &[_]u8{ 0, 51, 0, 2, 0, 0x1d });
        n += 6;
    }
    std.mem.writeInt(u16, out[ext_at..][0..2], @intCast(n - ext_at - 2), .big);
    out[0] = 2;
    out[1..4].* = u24be(n - 4);
    return n;
}

// ───────────── проверка ─────────────

test "расписание ключей: векторы RFC 8448" {
    // Простое рукопожатие 1-RTT из RFC 8448, раздел 3.
    const zeros = [_]u8{0} ** 32;
    var empty_hash: [32]u8 = undefined;
    Sha256.hash("", &empty_hash, .{});
    const early = Hkdf.extract(&zeros, &zeros);
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a");
    try std.testing.expectEqualSlices(u8, &want, &early);
    const derived = expandLabel(early, "derived", &empty_hash, 32);
    _ = try std.fmt.hexToBytes(&want, "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba");
    try std.testing.expectEqualSlices(u8, &want, &derived);
    var shared: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&shared, "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d");
    const hs = Hkdf.extract(&derived, &shared);
    _ = try std.fmt.hexToBytes(&want, "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac");
    try std.testing.expectEqualSlices(u8, &want, &hs);
    var th: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&th, "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8");
    const s_hs = expandLabel(hs, "s hs traffic", &th, 32);
    _ = try std.fmt.hexToBytes(&want, "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38");
    try std.testing.expectEqualSlices(u8, &want, &s_hs);
    const k = Keys.derive(.aes128, s_hs);
    var key: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "3fce516009c21727d0f2e4e86ee403bc");
    try std.testing.expectEqualSlices(u8, &key, k.key[0..16]);
    var iv: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&iv, "5d313eb2671276ee13000b30");
    try std.testing.expectEqualSlices(u8, &iv, &k.iv);
}

test "запись: шифрование туда и обратно, порча ловится" {
    inline for (.{ Suite.aes128, Suite.chacha }) |suite| {
        var a = Keys.derive(suite, [_]u8{7} ** 32);
        var b = Keys.derive(suite, [_]u8{7} ** 32);
        var rec: [200]u8 = undefined;
        const n = seal(suite, &a, 23, "GET / HTTP/1.1", &rec);
        var out: [200]u8 = undefined;
        const inner, const t = try open(suite, &b, rec[0..5], rec[5..n], &out);
        try std.testing.expectEqualStrings("GET / HTTP/1.1", inner);
        try std.testing.expectEqual(@as(u8, 23), t);
        const m = seal(suite, &a, 23, "x", &rec);
        rec[7] ^= 1;
        try std.testing.expectError(error.BadRecord, open(suite, &b, rec[0..5], rec[5..m], &out));
    }
}

test "враждебный ClientHello не роняет разбор" {
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var buf: [600]u8 = undefined;
    for (0..20000) |_| {
        const n = rnd.uintLessThan(usize, buf.len);
        rnd.bytes(buf[0..n]);
        _ = parseHello(buf[0..n], 0x0403) catch {};
    }
    var cfg = Config{ .key = .{ .ed25519 = Ed.KeyPair.generate() }, .cert_msg = &.{ 11, 0, 0, 4, 0, 0, 0, 0 } };
    for (0..2000) |_| {
        var s = Session{ .cfg = &cfg };
        const n = rnd.uintLessThan(usize, buf.len);
        rnd.bytes(buf[0..n]);
        if (n > 5 and rnd.boolean()) {
            buf[0] = 22;
            buf[3] = 0;
            buf[4] = @intCast(@min(n - 5, 255));
            buf[5] = 1;
        }
        s.feed(buf[0..n]) catch {};
    }
}
