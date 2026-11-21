//! Разбор аргументов.
//!
//!   clipper -p PORT [-r ROOTDIR] [-img ПАПКА] [-t flibusta|samlib|proza|nepomn] [-d auto|true|false|time]
//!           [-c ЦВЕТ] [-b ЦВЕТ] [-ico ФАЙЛ] [-png ФАЙЛ] [-btree] [-zstd [N|ФАЙЛ]] [-pdf] [-djvu] [-w N]
//!           [--tls-cert FILE --tls-key FILE] [-fed [ФАЙЛ.csv|-|сайт,сайт]]
//!           [-s АДРЕС] [-n НАЗВАНИЕ] [-l ЛОГИН] [-pwd ПАРОЛЬ | -phc СТРОКА]
//!   clipper fedcheck САЙТ                                 отвечает ли сайт как участник федерации
//!   clipper build [-r ROOTDIR] [-img ПАПКА] [-btree] [-zstd [N|ФАЙЛ]]   пересобрать снимок каталога
//!   clipper zstd N [-r ROOTDIR] [ПАПКА…]                    обучить словарь clipper<N>.zstd
//!   clipper hash ПАРОЛЬ                                   строка PHC (argon2id) для -phc
//!   clipper convert ФАЙЛ                                  книга → канонический текст (проверка разбора)
//!   clipper help

const std = @import("std");
const t9n = @import("t9n.zig");
const theme = @import("theme.zig");
const Config = @import("app.zig").Config;
const auth = @import("auth.zig");
const sections = @import("sections.zig");
const zfile = @import("zfile.zig");
const has_zstd = @import("config").zstd;
const has_pdf = @import("config").pdf;
const has_djvu = @import("config").djvu;

pub const Command = enum { serve, build, hash, convert, fedcheck, help, zstd };

pub const Args = struct {
    command: Command = .serve,
    cfg: Config = .{},
    password: []const u8 = "",
    /// clipper convert ФАЙЛ; clipper fedcheck САЙТ
    file: []const u8 = "",
    /// clipper zstd N [-r ROOTDIR] [ПАПКА…]: размер кадра, КБ, и папки с книгами
    zstd_kb: u32 = 0,
    dirs: []const []const u8 = &.{},
    /// Служебное: --worker … — этот процесс запущен главным как воркер.
    worker_spec: ?[]const u8 = null,
};

/// Справка `clipper help` на языке сборки (-Dlang): многострочные строки в каталог перевода не идут.
pub const usage = if (@import("config").lang == .en) usage_en else usage_ru;

const usage_en =
    \\clipper — a digital library
    \\
    \\  clipper -p PORT [-r ROOTDIR] [-img DIR] [-t THEME] [-d MODE] [-c COLOR] [-b COLOR] [-ico FILE] [-png FILE]
    \\          [-btree] [-zstd [N|FILE]] [-pdf] [-djvu] [-w N] [--tls-cert FILE --tls-key FILE] [-fed [WHAT]]
    \\          [-s ADDRESS] [-n NAME] [-l LOGIN] [-pwd PASSWORD | -phc STRING]
    \\
    \\    -p PORT            port (required)
    \\    -r ROOTDIR         library folder (the current one by default)
    \\    -img DIR           pictures folder: book pictures (DIR/b/) and board pictures;
    \\                       ROOTDIR/img by default; created if missing
    \\    -t THEME           default theme: flibusta, samlib, proza, nepomn
    \\    -d MODE            light or dark by default: auto — by device (default; with -c or -b — false),
    \\                       false — light, true — dark, time — by clock (dark from 20 to 7); -d=MODE also works
    \\    -c COLOR           core color (#rrggbb): all theme shades are recomputed from it;
    \\                       each theme has its own by default: flibusta #5294c1, samlib #0000ee, proza #000080, nepomn #416679
    \\    -b COLOR           brand color (#rrggbb): the proza logo (#60b050), the nepomn accent (#800000);
    \\                       without -b but with -c — contrasting to the core color (opposite hue)
    \\    -ico FILE          own site icon (.ico) instead of the built-in /favicon.ico
    \\    -png FILE          own logo (.png) instead of the built-in /logo64.png, /logo96.png, /logo120.png
    \\    -M SECTIONS        only moderators (the "staff" right) write, others read: -Mb
    \\    -R SECTIONS        read-only for everyone: -Rf
    \\    -G SECTIONS        open to guests (the rest after sign-in): -Gp
    \\    -N SECTIONS        off entirely (cannot be named in -M, -R, -G): -Nbdfq
    \\                       sections: p — poems, b — books, d — drafts, f — forums, q — quotes,
    \\                       v — recordings (only in builds with -Dvoice=true, the default);
    \\                       with -Nb and quotes on, books are hidden but readable from quotes
    \\    -s ADDRESS         site address, the proza theme is signed with it (clipper.localhost by default)
    \\    -n NAME            site name in titles and headers ("Clipper" by default)
    \\    -l LOGIN           login of the built-in administrator /u/0 (admin by default)
    \\    -pwd PASSWORD      /u/0 password in plain text
    \\    -phc STRING        /u/0 password as an argon2id PHC string (clipper hash PASSWORD); not with -pwd
    \\                       without a password /u/0 cannot sign in; /u/0 signs in only from this machine
    \\                       (localhost) — it is for setting up the site and creating your own administrator
    \\    -btree             keep records in a B+ tree (clipper.tree) rather than the journal
    \\    -zstd [N|FILE]     compress catalog frames with the built-in zstd and a dictionary file:
    \\                         N    — clipperN.zstd from the current folder, else from the program's folder
    \\                         FILE — this file (a path with / or \, or ending in .zstd)
    \\                         none — the dictionary the current snapshot was built with, else the largest
    \\                                clipperN.zstd; the frame size is taken from the file
    \\                       (only in builds with -Dzstd=true, the default; otherwise deflate)
    \\    -pdf, -djvu        allow uploading PDF and DjVu (experimental; text layer only, stored as text);
    \\                       without the flag nobody can upload them, whatever the panel says
    \\                       (only in builds with -Dpdf=true / -Ddjvu=true, the default)
    \\    -w N               worker processes (1–64, 1 by default)
    \\    --tls-cert FILE    certificate (PEM) — turns on https; only together with --tls-key
    \\    --tls-key FILE     private key (PEM): ECDSA P-256 or Ed25519
    \\    -fed [WHAT]        federation: sign-in from other Clipper sites here and from here to them
    \\                         no value  — the list in ROOTDIR/FEDIVERSE.csv (created),
    \\                                     new sites are added to it automatically
    \\                         FILE.csv  — the same with another file
    \\                         -         — FEDIVERSE.csv, but only the sites named in it
    \\                         a.ru,b.ru — only these sites, both ways, no file
    \\                       file line: domain,authInsideService,authOutsideService
    \\                       (true|1, false|0, empty — as in the localhost line)
    \\
    \\  clipper build [-r ROOTDIR] [-img DIR] [-btree] [-zstd [N|FILE]]    rebuild the catalog snapshot from books/
    \\  clipper zstd N [-r ROOTDIR] [DIR...]          train a zstd dictionary for N KB frames (4–32) into
    \\                                                clipperN.zstd here: on the library's own texts, or on the
    \\                                                books in DIR... (fb2, epub, pdf, djvu, txt, recursively)
    \\  clipper hash PASSWORD                               argon2id PHC string for -phc
    \\  clipper convert FILE                                book (fb2, epub, pdf, djvu, txt) → canonical text
    \\  clipper fedcheck SITE                               does the site answer as a federation member
    \\
;

const usage_ru =
    \\clipper — цифровая библиотека
    \\
    \\  clipper -p PORT [-r ROOTDIR] [-img ПАПКА] [-t ТЕМА] [-d РЕЖИМ] [-c ЦВЕТ] [-b ЦВЕТ] [-ico ФАЙЛ] [-png ФАЙЛ]
    \\          [-btree] [-zstd [N|ФАЙЛ]] [-pdf] [-djvu] [-w N] [--tls-cert FILE --tls-key FILE] [-fed [ЧТО]]
    \\          [-s АДРЕС] [-n НАЗВАНИЕ] [-l ЛОГИН] [-pwd ПАРОЛЬ | -phc СТРОКА]
    \\
    \\    -p PORT            порт (обязателен)
    \\    -r ROOTDIR         папка библиотеки (по умолчанию текущая)
    \\    -img ПАПКА         папка картинок: картинки книг (ПАПКА/b/) и досок;
    \\                       по умолчанию ROOTDIR/img; нет — создаётся
    \\    -t ТЕМА            тема по умолчанию: flibusta, samlib, proza, nepomn
    \\    -d РЕЖИМ           светлая или тёмная по умолчанию: auto — по устройству (по умолчанию; с -c или -b — false),
    \\                       false — светлая, true — тёмная, time — по часам (тёмная с 20 до 7); можно -d=РЕЖИМ
    \\    -c ЦВЕТ            главный цвет (#rrggbb): все оттенки тем пересчитываются от него;
    \\                       по умолчанию у тем свой: flibusta #5294c1, samlib #0000ee, proza #000080, nepomn #416679
    \\    -b ЦВЕТ            фирменный цвет (#rrggbb): логотип proza (#60b050), акцент nepomn (#800000);
    \\                       без -b, но с -c — контрастный главному (тон напротив)
    \\    -ico ФАЙЛ          свой значок сайта (.ico) вместо встроенного /favicon.ico
    \\    -png ФАЙЛ          свой логотип (.png) вместо встроенного /logo64.png, /logo96.png, /logo120.png
    \\    -M РАЗДЕЛЫ         пишут только модераторы (право «сотрудник»), прочим — чтение: -Mb
    \\    -R РАЗДЕЛЫ         только чтение для всех: -Rf
    \\    -G РАЗДЕЛЫ         открыто гостям (прочее — после входа): -Gp
    \\    -N РАЗДЕЛЫ         выключено совсем (нельзя упоминать в -M, -R, -G): -Nbdfq
    \\                       разделы: p — стихи, b — книги, d — черновики, f — форумы, q — цитаты,
    \\                       v — записи (только в сборке с -Dvoice=true, по умолчанию);
    \\                       при -Nb и включённых цитатах книги скрыты, но читаются из цитат
    \\    -s АДРЕС           адрес сайта, им подписана тема proza (по умолчанию clipper.localhost)
    \\    -n НАЗВАНИЕ        название сайта в заголовках и шапках (по умолчанию «Клиппер»)
    \\    -l ЛОГИН           логин встроенного администратора /u/0 (по умолчанию admin)
    \\    -pwd ПАРОЛЬ        пароль /u/0 открытым текстом
    \\    -phc СТРОКА        пароль /u/0 строкой PHC argon2id (clipper hash ПАРОЛЬ); не вместе с -pwd
    \\                       без пароля в /u/0 не войти; вход /u/0 — только с этой машины (localhost),
    \\                       он нужен, чтобы настроить сайт и завести своего администратора
    \\    -btree             хранить записи в B+ дереве (clipper.tree), а не в журнале
    \\    -zstd [N|ФАЙЛ]     сжимать кадры каталога своим zstd со словарём из файла:
    \\                         N        — clipperN.zstd из текущей папки, иначе из папки программы
    \\                         ФАЙЛ     — этот файл (путь с / или \ либо на .zstd)
    \\                         без него — словарь, с которым собран текущий снимок, иначе наибольший
    \\                                    clipperN.zstd; размер кадра — из файла
    \\                       (только в сборке с -Dzstd=true, по умолчанию; иначе deflate)
    \\    -pdf, -djvu        разрешить загрузку PDF и DjVu (экспериментально; только с текстовым слоем,
    \\                       хранится текст); без флага их не загрузит никто, что бы ни сказала панель
    \\                       (только в сборке с -Dpdf=true / -Ddjvu=true, по умолчанию)
    \\    -w N              процессов-воркеров (1–64, по умолчанию 1)
    \\    --tls-cert FILE    сертификат (PEM) — включает https; только вместе с --tls-key
    \\    --tls-key FILE     закрытый ключ (PEM): ECDSA P-256 или Ed25519
    \\    -fed [ЧТО]         федерация: вход с других сайтов Клиппер сюда и отсюда на них
    \\                         без значения — список в ROOTDIR/FEDIVERSE.csv (создаётся),
    \\                                        новые сайты дописываются в него сами
    \\                         ФАЙЛ.csv     — то же с другим файлом
    \\                         -            — FEDIVERSE.csv, но только названные в нём сайты
    \\                         a.ru,b.ru    — только эти сайты, в обе стороны, без файла
    \\                       строка файла: domain,authInsideService,authOutsideService
    \\                       (true|1, false|0, пусто — как в строке localhost)
    \\
    \\  clipper build [-r ROOTDIR] [-img ПАПКА] [-btree] [-zstd [N|ФАЙЛ]]    пересобрать снимок каталога из books/
    \\  clipper zstd N [-r ROOTDIR] [ПАПКА...]        обучить словарь zstd для кадров N КБ (4–32) в clipperN.zstd
    \\                                                здесь: на текстах своей библиотеки или на книгах в ПАПКАх
    \\                                                (fb2, epub, pdf, djvu, txt, с подпапками)
    \\  clipper hash ПАРОЛЬ                                 строка PHC argon2id для -phc
    \\  clipper convert ФАЙЛ                                книга (fb2, epub, pdf, djvu, txt) → канонический текст
    \\  clipper fedcheck САЙТ                               отвечает ли сайт как участник федерации
    \\
;

/// Годится ли значение -s (адрес) или -n (название): непустой UTF-8 без
/// управляющих символов; в адресе к тому же нет пробелов и знаков разметки.
fn labelOk(v: []const u8, is_site: bool) bool {
    if (v.len == 0 or v.len > 100 or !std.unicode.utf8ValidateSlice(v)) return false;
    for (v) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
        if (is_site and std.mem.indexOfScalar(u8, " /\\<>\"'&", ch) != null) return false;
    }
    return std.mem.trim(u8, v, " ").len == v.len;
}

/// Ошибка разбора — понятная строка в `msg` и error.Usage.
pub fn parse(argv: []const []const u8, msg: *[]const u8) error{Usage}!Args {
    var a = Args{};
    var i: usize = 1;
    var have_port = false;
    var d_set = false;
    if (argv.len > 1) {
        if (std.mem.eql(u8, argv[1], "build")) {
            a.command = .build;
            i = 2;
        } else if (std.mem.eql(u8, argv[1], "hash")) {
            if (argv.len != 3 or argv[2].len == 0) {
                msg.* = t9n.tr("clipper hash: нужен один аргумент — пароль");
                return error.Usage;
            }
            a.command = .hash;
            a.password = argv[2];
            return a;
        } else if (std.mem.eql(u8, argv[1], "convert")) {
            if (argv.len != 3 or argv[2].len == 0) {
                msg.* = t9n.tr("clipper convert: нужен один аргумент — файл книги");
                return error.Usage;
            }
            a.command = .convert;
            a.file = argv[2];
            return a;
        } else if (std.mem.eql(u8, argv[1], "fedcheck")) {
            if (argv.len != 3 or argv[2].len == 0) {
                msg.* = t9n.tr("clipper fedcheck: нужен один аргумент — сайт (example.com или http://localhost:3001)");
                return error.Usage;
            }
            a.command = .fedcheck;
            a.file = argv[2];
            return a;
        } else if (has_zstd and std.mem.eql(u8, argv[1], "zstd")) {
            return parseZstd(argv, msg);
        } else if (std.mem.eql(u8, argv[1], "help") or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
            a.command = .help;
            return a;
        }
    }
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const eq = std.mem.eql;
        if (eq(u8, arg, "-s") or eq(u8, arg, "-n")) {
            const is_site = arg[1] == 's';
            i += 1;
            const v = if (i < argv.len) argv[i] else "";
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            if (!labelOk(v, is_site)) {
                msg.* = if (is_site) t9n.tr("после -s нужен адрес сайта, например clipper.to (до 100 байт, без пробелов и знаков / < > \" &)") else t9n.tr("после -n нужно название сайта, например \"Клиппер\" (до 100 байт)");
                return error.Usage;
            }
            if (is_site) a.cfg.site = v else a.cfg.name = v;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-d=") or eq(u8, arg, "-d")) {
            var v: []const u8 = undefined;
            if (arg.len > 2) v = arg[3..] else {
                i += 1;
                v = if (i < argv.len) argv[i] else "";
            }
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            d_set = true;
            a.cfg.mode = if (eq(u8, v, "auto")) .auto else if (eq(u8, v, "true")) .dark else if (eq(u8, v, "false")) .light else if (eq(u8, v, "time")) .time else {
                msg.* = t9n.tr("-d: auto (по устройству), true (тёмная), false (светлая) или time (по часам)");
                return error.Usage;
            };
            continue;
        }
        if (eq(u8, arg, "-c") or eq(u8, arg, "-b") or eq(u8, arg, "-ico") or eq(u8, arg, "-png")) {
            i += 1;
            const v = if (i < argv.len) argv[i] else "";
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            if (eq(u8, arg, "-c") or eq(u8, arg, "-b")) {
                const c = theme.parseColor(v) orelse {
                    msg.* = if (arg[1] == 'c') t9n.tr("после -c нужен главный цвет: #rrggbb или #rgb") else t9n.tr("после -b нужен фирменный цвет: #rrggbb или #rgb");
                    return error.Usage;
                };
                if (arg[1] == 'c') a.cfg.core = c else a.cfg.brand = c;
            } else {
                if (v.len == 0) {
                    msg.* = if (eq(u8, arg, "-ico")) t9n.tr("после -ico нужен файл значка (.ico)") else t9n.tr("после -png нужен файл логотипа (.png)");
                    return error.Usage;
                }
                if (eq(u8, arg, "-ico")) a.cfg.ico = v else a.cfg.png = v;
            }
            continue;
        }
        // -M, -R, -G, -N и буквы разделов слитно: -Mb, -Rf, -Gp, -Nbdfq
        if (arg.len >= 2 and arg[0] == '-' and std.mem.indexOfScalar(u8, "MRGN", arg[1]) != null) {
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            const set = sections.parseSet(arg[2..], msg) orelse return error.Usage;
            const r = &a.cfg.sec;
            const target = switch (arg[1]) {
                'M' => &r.mod,
                'R' => &r.ro,
                'G' => &r.guest,
                else => &r.off,
            };
            if (target.* & set != 0) {
                msg.* = t9n.tr("буква раздела повторяется в одном флаге (-M, -R, -G или -N)");
                return error.Usage;
            }
            target.* |= set;
            if (arg[1] == 'G') r.guest_set = true;
            continue;
        }
        if (eq(u8, arg, "-l") or eq(u8, arg, "-pwd") or eq(u8, arg, "-phc")) {
            i += 1;
            const v = if (i < argv.len) argv[i] else "";
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            if (eq(u8, arg, "-l")) {
                if (!labelOk(v, true) or v.len > 40) {
                    msg.* = t9n.tr("после -l нужен логин администратора (до 40 байт, без пробелов)");
                    return error.Usage;
                }
                a.cfg.admin_login = v;
            } else if (eq(u8, arg, "-pwd")) {
                if (v.len < 4 or v.len > 200) {
                    msg.* = t9n.tr("после -pwd нужен пароль /u/0 (от 4 до 200 байт)");
                    return error.Usage;
                }
                a.cfg.admin_pass = v;
            } else {
                if (!auth.phcOk(v)) {
                    msg.* = t9n.tr("после -phc нужна строка PHC argon2id ($argon2id$...); её печатает clipper hash ПАРОЛЬ");
                    return error.Usage;
                }
                a.cfg.admin_phc = v;
            }
            continue;
        }
        const needs_value = eq(u8, arg, "-p") or eq(u8, arg, "-r") or eq(u8, arg, "-img") or eq(u8, arg, "-t") or eq(u8, arg, "--tls-cert") or eq(u8, arg, "--tls-key") or eq(u8, arg, "-w") or eq(u8, arg, "--worker");
        if (needs_value) {
            if (i + 1 >= argv.len) {
                msg.* = if (eq(u8, arg, "-w") or eq(u8, arg, "--worker")) t9n.tr("после -w нужно число воркеров от 1 до 64") else if (eq(u8, arg, "-p")) t9n.tr("после -p нужен номер порта") else if (eq(u8, arg, "-r")) t9n.tr("после -r нужна папка библиотеки") else if (eq(u8, arg, "-img")) t9n.tr("после -img нужна папка картинок") else if (eq(u8, arg, "-t")) t9n.tr("после -t нужна тема: flibusta, samlib, proza, nepomn") else t9n.tr("после --tls-cert и --tls-key нужен файл");
                return error.Usage;
            }
            i += 1;
            const v = argv[i];
            if (eq(u8, arg, "-p")) {
                const port = std.fmt.parseInt(u16, v, 10) catch 0;
                if (port == 0) {
                    msg.* = t9n.tr("неверный порт: нужно число от 1 до 65535");
                    return error.Usage;
                }
                a.cfg.port = port;
                have_port = true;
            } else if (eq(u8, arg, "-r")) {
                if (v.len == 0) {
                    msg.* = t9n.tr("после -r нужна папка библиотеки");
                    return error.Usage;
                }
                a.cfg.root = v;
            } else if (eq(u8, arg, "-img")) {
                if (v.len == 0) {
                    msg.* = t9n.tr("после -img нужна папка картинок");
                    return error.Usage;
                }
                a.cfg.img = v;
            } else if (eq(u8, arg, "-t")) {
                a.cfg.theme = theme.baseOf(v) orelse {
                    msg.* = t9n.tr("неизвестная тема: бывают flibusta, samlib, proza, nepomn");
                    return error.Usage;
                };
            } else if (eq(u8, arg, "-w")) {
                const n = std.fmt.parseInt(u32, v, 10) catch 0;
                if (n < 1 or n > 64) {
                    msg.* = t9n.tr("после -w нужно число воркеров от 1 до 64");
                    return error.Usage;
                }
                a.cfg.workers = n;
            } else if (eq(u8, arg, "--worker")) {
                a.worker_spec = v;
            } else if (eq(u8, arg, "--tls-cert")) {
                a.cfg.tls_cert = v;
            } else a.cfg.tls_key = v;
        } else if (eq(u8, arg, "-fed")) {
            // значение необязательно: следующий аргумент, если он не флаг («-» — значение)
            a.cfg.fed = "";
            if (i + 1 < argv.len and argv[i + 1].len > 0 and (argv[i + 1][0] != '-' or argv[i + 1].len == 1)) {
                i += 1;
                a.cfg.fed = argv[i];
            }
        } else if (has_zstd and eq(u8, arg, "-zstd")) {
            // при -Dzstd=false этой ветки нет вовсе: -zstd — неизвестный аргумент.
            // Значение необязательно: число — clipper<N>.zstd, путь — файл.
            a.cfg.zstd = .auto;
            if (i + 1 < argv.len) {
                const v = argv[i + 1];
                if (v.len > 0 and std.ascii.isDigit(v[0])) {
                    const n = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (!zfile.kbOk(n)) {
                        msg.* = t9n.tr("-zstd N: размер кадра от 4 до 32 КБ (страница чтения не больше 32 КБ)");
                        return error.Usage;
                    }
                    a.cfg.zstd = .{ .kb = n };
                    i += 1;
                } else if (std.mem.indexOfAny(u8, v, "/\\") != null or std.ascii.endsWithIgnoreCase(v, ".zstd")) {
                    a.cfg.zstd = .{ .path = v };
                    i += 1;
                }
            }
        } else if (has_pdf and eq(u8, arg, "-pdf")) {
            // при -Dpdf=false этой ветки нет: -pdf — неизвестный аргумент
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            a.cfg.pdf = true;
        } else if (has_djvu and eq(u8, arg, "-djvu")) {
            if (a.command == .build) {
                msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
                return error.Usage;
            }
            a.cfg.djvu = true;
        } else if (eq(u8, arg, "-btree")) {
            a.cfg.btree = true;
        } else {
            msg.* = t9n.tr("неизвестный аргумент (clipper help — справка)");
            return error.Usage;
        }
    }
    if (a.command == .build) {
        if (have_port or a.cfg.tls_cert != null or a.cfg.tls_key != null or a.cfg.workers != 1 or a.worker_spec != null or a.cfg.fed != null) {
            msg.* = t9n.tr("clipper build понимает только -r, -img, -btree и -zstd");
            return error.Usage;
        }
        return a;
    }
    if (!have_port) {
        msg.* = t9n.tr("нужен порт: clipper -p PORT (clipper help — справка)");
        return error.Usage;
    }
    if (!sections.check(a.cfg.sec, msg)) return error.Usage;
    // свои цвета подобраны под светлую тему: без -d она и включается
    if (!d_set and (a.cfg.core != null or a.cfg.brand != null)) a.cfg.mode = .light;
    if (a.cfg.admin_pass != null and a.cfg.admin_phc != null) {
        msg.* = t9n.tr("-pwd и -phc вместе не задаются: пароль /u/0 — либо открытым текстом, либо строкой PHC");
        return error.Usage;
    }
    if ((a.cfg.tls_cert == null) != (a.cfg.tls_key == null)) {
        msg.* = t9n.tr("--tls-cert и --tls-key задаются только вместе");
        return error.Usage;
    }
    return a;
}

/// clipper zstd N [-r ROOTDIR] [ПАПКА…]
fn parseZstd(argv: []const []const u8, msg: *[]const u8) error{Usage}!Args {
    var a = Args{ .command = .zstd };
    const n = if (argv.len > 2) std.fmt.parseInt(u32, argv[2], 10) catch 0 else 0;
    if (!zfile.kbOk(n)) {
        msg.* = t9n.tr("clipper zstd N [-r ROOTDIR] [ПАПКА…]: N — размер кадра от 4 до 32 КБ");
        return error.Usage;
    }
    a.zstd_kb = n;
    var i: usize = 3;
    if (i < argv.len and std.mem.eql(u8, argv[i], "-r")) {
        if (i + 1 >= argv.len or argv[i + 1].len == 0) {
            msg.* = t9n.tr("после -r нужна папка библиотеки");
            return error.Usage;
        }
        a.cfg.root = argv[i + 1];
        i += 2;
    }
    for (argv[i..]) |d| if (d.len == 0 or d[0] == '-') {
        msg.* = t9n.tr("clipper zstd N [-r ROOTDIR] [ПАПКА…]: после N — только -r и папки с книгами");
        return error.Usage;
    };
    a.dirs = argv[i..];
    return a;
}

test "-img" {
    var msg: []const u8 = "";
    try std.testing.expect((try parse(&.{ "clipper", "-p", "80" }, &msg)).cfg.img == null);
    try std.testing.expectEqualStrings("D:/pics", (try parse(&.{ "clipper", "-p", "80", "-img", "D:/pics" }, &msg)).cfg.img.?);
    try std.testing.expectEqualStrings("p", (try parse(&.{ "clipper", "build", "-img", "p" }, &msg)).cfg.img.?);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-img" }, &msg));
}

test "-pdf и -djvu" {
    var msg: []const u8 = "";
    const off = try parse(&.{ "clipper", "-p", "80" }, &msg);
    try std.testing.expect(!off.cfg.pdf and !off.cfg.djvu);
    if (has_pdf) try std.testing.expect((try parse(&.{ "clipper", "-p", "80", "-pdf" }, &msg)).cfg.pdf) else try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-pdf" }, &msg));
    if (has_djvu) try std.testing.expect((try parse(&.{ "clipper", "-p", "80", "-djvu" }, &msg)).cfg.djvu) else try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-djvu" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "build", "-pdf" }, &msg));
}

test "-zstd и clipper zstd" {
    if (!has_zstd) return;
    var msg: []const u8 = "";
    try std.testing.expectEqual(zfile.Spec.off, (try parse(&.{ "clipper", "-p", "80" }, &msg)).cfg.zstd);
    try std.testing.expectEqual(zfile.Spec.auto, (try parse(&.{ "clipper", "-p", "80", "-zstd" }, &msg)).cfg.zstd);
    try std.testing.expectEqual(zfile.Spec.auto, (try parse(&.{ "clipper", "-zstd", "-p", "80" }, &msg)).cfg.zstd);
    try std.testing.expectEqual(@as(u32, 32), (try parse(&.{ "clipper", "-p", "80", "-zstd", "32" }, &msg)).cfg.zstd.kb);
    try std.testing.expectEqualStrings("d/my.zstd", (try parse(&.{ "clipper", "-p", "80", "-zstd", "d/my.zstd" }, &msg)).cfg.zstd.path);
    try std.testing.expectEqualStrings("my.zstd", (try parse(&.{ "clipper", "-zstd", "my.zstd", "-p", "80" }, &msg)).cfg.zstd.path);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-zstd", "64" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-zstd", "2" }, &msg));
    // не путь и не число — не значение -zstd, а чужой аргумент
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-zstd", "mydict" }, &msg));
    try std.testing.expectEqual(@as(u32, 16), (try parse(&.{ "clipper", "build", "-zstd", "16" }, &msg)).cfg.zstd.kb);
    const z = try parse(&.{ "clipper", "zstd", "16", "-r", "lib", "a", "b" }, &msg);
    try std.testing.expectEqual(Command.zstd, z.command);
    try std.testing.expectEqual(@as(u32, 16), z.zstd_kb);
    try std.testing.expectEqualStrings("lib", z.cfg.root);
    try std.testing.expectEqual(@as(usize, 2), z.dirs.len);
    try std.testing.expectEqual(@as(usize, 0), (try parse(&.{ "clipper", "zstd", "32" }, &msg)).dirs.len);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "zstd" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "zstd", "64" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "zstd", "16", "a", "-btree" }, &msg));
}

test "флаги" {
    var msg: []const u8 = "";
    const ok = try parse(&.{ "clipper", "-p", "3000", "-t", "samlib", "-btree", "-r", "lib" }, &msg);
    try std.testing.expectEqual(@as(u16, 3000), ok.cfg.port);
    try std.testing.expectEqual(theme.Base.samlib, ok.cfg.theme);
    try std.testing.expect(ok.cfg.btree);
    try std.testing.expectEqualStrings("lib", ok.cfg.root);
    try std.testing.expectError(error.Usage, parse(&.{"clipper"}, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "0" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "70000" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-t", "dark" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "--tls-cert", "c.pem" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "--prod" }, &msg));
    try std.testing.expectEqual(Command.build, (try parse(&.{ "clipper", "build", "-btree" }, &msg)).command);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "build", "-p", "1" }, &msg));
    try std.testing.expectEqual(@as(u32, 1), ok.cfg.workers);
    try std.testing.expectEqual(@as(u32, 4), (try parse(&.{ "clipper", "-p", "80", "-w", "4" }, &msg)).cfg.workers);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-w", "0" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-w", "65" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "build", "-w", "2" }, &msg));
    // -fed: значение необязательно
    try std.testing.expect(ok.cfg.fed == null);
    try std.testing.expectEqualStrings("", (try parse(&.{ "clipper", "-p", "80", "-fed" }, &msg)).cfg.fed.?);
    try std.testing.expectEqualStrings("", (try parse(&.{ "clipper", "-fed", "-p", "80" }, &msg)).cfg.fed.?);
    try std.testing.expectEqualStrings("-", (try parse(&.{ "clipper", "-fed", "-", "-p", "80" }, &msg)).cfg.fed.?);
    try std.testing.expectEqualStrings("a.ru,b.ru", (try parse(&.{ "clipper", "-p", "80", "-fed", "a.ru,b.ru" }, &msg)).cfg.fed.?);
    try std.testing.expectEqualStrings("my.csv", (try parse(&.{ "clipper", "-p", "80", "-fed", "my.csv", "-btree" }, &msg)).cfg.fed.?);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "build", "-fed" }, &msg));
    try std.testing.expectEqual(Command.fedcheck, (try parse(&.{ "clipper", "fedcheck", "example.com" }, &msg)).command);
    // -s и -n: адрес и название сайта
    try std.testing.expectEqualStrings("clipper.localhost", ok.cfg.site);
    try std.testing.expectEqualStrings(t9n.tr("Клиппер"), ok.cfg.name);
    const named = try parse(&.{ "clipper", "-p", "80", "-s", "clipper.to", "-n", "Моя библиотека" }, &msg);
    try std.testing.expectEqualStrings("clipper.to", named.cfg.site);
    try std.testing.expectEqualStrings("Моя библиотека", named.cfg.name);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-s" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-s", "http://a.ru" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-n", "" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "build", "-n", "x" }, &msg));
}

test "цвета, режим, картинки" {
    var msg: []const u8 = "";
    const a = try parse(&.{ "clipper", "-p", "80", "-c", "#c15252", "-b", "123", "-d=true", "-ico", "a.ico", "-png", "a.png" }, &msg);
    try std.testing.expectEqual(theme.Rgb{ 0xc1, 0x52, 0x52 }, a.cfg.core.?);
    try std.testing.expectEqual(theme.Rgb{ 0x11, 0x22, 0x33 }, a.cfg.brand.?);
    try std.testing.expectEqual(theme.Mode.dark, a.cfg.mode);
    try std.testing.expectEqualStrings("a.ico", a.cfg.ico.?);
    try std.testing.expectEqual(theme.Mode.time, (try parse(&.{ "clipper", "-p", "80", "-d", "time" }, &msg)).cfg.mode);
    try std.testing.expectEqual(theme.Mode.light, (try parse(&.{ "clipper", "-p", "80", "-d=false" }, &msg)).cfg.mode);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-d", "maybe" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-c", "red" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "--btree" }, &msg));
    // -c или -b без -d — светлая; явный -d важнее
    try std.testing.expectEqual(theme.Mode.light, (try parse(&.{ "clipper", "-p", "80", "-c", "#123456" }, &msg)).cfg.mode);
    try std.testing.expectEqual(theme.Mode.light, (try parse(&.{ "clipper", "-p", "80", "-b", "#123456" }, &msg)).cfg.mode);
    try std.testing.expectEqual(theme.Mode.time, (try parse(&.{ "clipper", "-p", "80", "-c", "#123456", "-d", "time" }, &msg)).cfg.mode);
    try std.testing.expectEqual(theme.Mode.auto, (try parse(&.{ "clipper", "-p", "80" }, &msg)).cfg.mode);
}

test "разделы: флаги" {
    var msg: []const u8 = "";
    const a = try parse(&.{ "clipper", "-p", "80", "-Mb", "-Rf", "-Gp", "-Nd" }, &msg);
    try std.testing.expectEqual(sections.bit(.b), a.cfg.sec.mod);
    try std.testing.expectEqual(sections.bit(.d), a.cfg.sec.off);
    try std.testing.expect(a.cfg.sec.guest_set);
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-Nb", "-Mb" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-Mbb" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-Mx" }, &msg));
    try std.testing.expectError(error.Usage, parse(&.{ "clipper", "-p", "80", "-N" ++ sections.letters }, &msg));
}
