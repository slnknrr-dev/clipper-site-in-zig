//! Корень модуля: его тесты — модульные тесты всех файлов; test/all.zig
//! импортирует его как "clipper" для сквозных проверок.
pub const t9n = @import("t9n.zig");
pub const sections = @import("sections.zig");
pub const cp1251 = @import("cp1251.zig");
pub const out = @import("out.zig");
pub const http = @import("http.zig");
pub const sys = @import("sys.zig");
pub const journal = @import("journal.zig");
pub const btree = @import("btree.zig");
pub const ledger = @import("ledger.zig");
pub const net = @import("net/net.zig");
pub const server = @import("net/server.zig");
pub const tls = @import("net/tls.zig");
pub const cache = @import("cache.zig");
pub const snapshot = @import("snapshot.zig");
pub const fb2 = @import("fb2.zig");
pub const theme = @import("theme.zig");
pub const tpl = @import("tpl.zig");
pub const db = @import("db.zig");
pub const auth = @import("auth.zig");
pub const library = @import("library.zig");
pub const zstd = @import("zstd.zig");
pub const zdict = @import("zdict.zig");
pub const zfile = @import("zfile.zig");
pub const imgstore = @import("imgstore.zig");
pub const image = @import("img/image.zig");
pub const png = @import("img/png.zig");
pub const jpeg = @import("img/jpeg.zig");
pub const gif = @import("img/gif.zig");
pub const webp = @import("img/webp.zig");
pub const svg = @import("img/svg.zig");
pub const chordpro = @import("chordpro.zig");
pub const app = @import("app.zig");
pub const layout = @import("layout.zig");
pub const route = @import("route.zig");
pub const cli = @import("cli.zig");
pub const workers = @import("workers.zig");
pub const badge = @import("badge.zig");
pub const @"export" = @import("export.zig");
pub const marks = @import("pages/marks.zig");
pub const home = @import("pages/home.zig");
pub const import = @import("import.zig");
pub const import_common = @import("import/common.zig");
pub const epub = @import("import/epub.zig");
pub const pdf = if (@import("config").pdf) @import("import/pdf.zig") else struct {};
pub const djvu = if (@import("config").djvu) @import("import/djvu.zig") else struct {};
pub const pdf_test = if (@import("config").pdf) @import("import/pdf_test.zig") else struct {};
pub const fed = @import("fed.zig");
pub const client = @import("net/client.zig");
pub const fed_pages = @import("pages/fed.zig");
pub const audio = if (@import("config").voice) @import("audio/audio.zig") else struct {};
pub const voice = @import("pages/voice.zig");

test {
    inline for (.{ t9n, sections, cp1251, out, http, sys, journal, btree, ledger, net, server, tls, cache, snapshot, fb2, theme, tpl, db, auth, library, zstd, zdict, zfile, imgstore, image, png, jpeg, gif, webp, svg, chordpro, app, layout, route, cli, badge, @"export", marks, home, import, import_common, epub, pdf, djvu, pdf_test, fed, client, fed_pages, audio, voice }) |m| _ = m;
}
