//! Тестовая заготовка: данные, на которых проверяется сайт (сравнение с макетом,
//! враждебный ввод, архетипы, федерация). В программу они не попадают: сайт
//! начинается пустым, а эти записи кладут в хранилище только тесты —
//! `seed(...)` в сквозных тестах и `zig build fixture -- ПАПКА` перед запуском
//! сервера для node-тестов. Классика из общественного достояния и тексты,
//! написанные для макета; учётные записи — пароль совпадает с логином.

const std = @import("std");
const clipper = @import("clipper");
const cp = clipper.cp1251;
const snap = clipper.snapshot;
const dbm = clipper.db;
const L = clipper.ledger;

const T = cp.text;

pub const persons = [_]snap.InPerson{
    .{ .id = 1, .name = T("Александр Пушкин"), .years = T("1799–1837"), .about = T("Поэт, прозаик, драматург.") },
    .{ .id = 2, .name = T("Михаил Лермонтов"), .years = T("1814–1841"), .about = T("Поэт, прозаик.") },
    .{ .id = 3, .name = T("Антон Чехов"), .years = T("1860–1904"), .about = T("Писатель, драматург, врач.") },
    .{ .id = 4, .name = T("Фёдор Тютчев"), .years = T("1803–1873"), .about = T("Поэт, дипломат.") },
};

pub const pieces = [_]snap.InPiece{
    .{ .id = 1, .title = T("Пророк (фрагмент)"), .author = 1, .genre = T("стихи"), .year = "1826", .text = T("Духовной жаждою томим,\nВ пустыне мрачной я влачился, —\nИ шестикрылый серафим\nНа перепутье мне явился.") },
    .{ .id = 2, .title = T("Парус"), .author = 2, .genre = T("стихи"), .year = "1832", .text = T("Белеет парус одинокой\nВ тумане моря голубом!..\nЧто ищет он в стране далекой?\nЧто кинул он в краю родном?..") },
    .{ .id = 3, .title = T("Silentium! (фрагмент)"), .author = 4, .genre = T("стихи"), .year = "1830", .text = T("Молчи, скрывайся и таи\nИ чувства и мечты свои —\nПускай в душевной глубине\nВстают и заходят оне") },
    .{ .id = 4, .title = T("Ночная трасса"), .author = -101, .genre = T("верлибр"), .year = "2003", .text = T("фонари\nкак запятые\nв длинном предложении\nкоторое никто не дочитает\n\nи только дальнобойщик\nставит точку\nу заправки") },
    .{ .id = 5, .title = T("Песенка про чайник"), .author = -102, .genre = T("авторская песня"), .year = "2002", .text = T("Кипит наш чайник на плите,\nИ пар плывёт под потолок,\nА мы сидим, как в темноте,\nИ слушаем его свисток.") },
    .{ .id = -1, .title = T("Вальс у заправки"), .author = -101, .genre = T("песня с нотами"), .year = "2003", .text = T("Ночь, бензин и ветер,\nДальний свет в окне...\nКто за всё ответит —\nТот споёт и мне."), .chords = T("Am        Dm\nНочь, бензин и ветер,\nG          C\nДальний свет в окне...\nAm       Dm\nКто за всё ответит —\nE         Am\nТот споёт и мне."), .notes = T("X:1\nT:Вальс у заправки\nM:3/4\nL:1/4\nK:Am\n|: A2 c | e2 d | c B A | E3 |\n   d2 f | a2 g | f e d | e3 :|") },
    .{ .id = -2, .title = T("Свисток (песня)"), .author = -102, .genre = T("песня с нотами"), .year = "2002", .text = T("Кипит наш чайник на плите..."), .chords = T("C   G   Am   F\nКипит наш чайник на плите"), .notes = T("X:2\nT:Свисток\nM:4/4\nL:1/8\nK:C\n|C2E2 G2E2|F2A2 G4|E2G2 c2B2|A2G2 C4|") },
};


pub const User = struct { id: i32, login: []const u8, nick: []const u8, joined: []const u8, about: []const u8, rights: u8 = dbm.rights.default };

pub const users = [_]User{
    .{ .id = 1001, .login = "librarian", .nick = "librarian", .joined = "2002-09-01", .about = T("Хранитель полок. Модератор."), .rights = dbm.rights.default | dbm.rights.upload },
    .{ .id = 1002, .login = "reader", .nick = "chitatel_77", .joined = "2003-02-11", .about = T("Читаю всё подряд.") },
    .{ .id = -101, .login = "vetrov", .nick = T("Ветров (Upbuilder)"), .joined = "2002-11-05", .about = T("Пишет прозу про дороги и стихи без рифмы."), .rights = dbm.rights.default | dbm.rights.upload },
    .{ .id = -102, .login = "samovarova", .nick = T("Самоварова (Unveiler)"), .joined = "2002-12-20", .about = T("Бард, статьи о библиотечном деле."), .rights = dbm.rights.default | dbm.rights.upload },
};


pub const characters = [_]dbm.Person{
    .{ .id = -1, .name = T("Сильвио"), .about = T("Герой повести «Выстрел»."), .author = 1, .books = "" },
    .{ .id = -2, .name = T("Печорин"), .about = T("Главный герой романа."), .author = 2, .books = "" },
    .{ .id = -3, .name = T("Максим Максимыч"), .about = T("Штабс-капитан, рассказчик «Бэлы»."), .author = 2, .books = "" },
    .{ .id = -4, .name = T("Евгений Онегин"), .about = T("Персонаж Пушкина без привязки к книге библиотеки."), .author = 1, .books = "" },
    .{ .id = -5, .name = T("Сменщик"), .about = T("Заправщик из дорожного цикла."), .author = -101, .books = "" },
};

pub const drafts = [_]dbm.Draft{
    .{ .id = 1, .title = T("Набросок: колонка номер три"), .author = -101, .created = "2003-05-11", .moved = "", .tags = T("проза,фрагмент"), .text = T("Колонка номер три капризничала с весны. Её чинили, ругали, гладили...") },
    .{ .id = 2, .title = T("Хокку про снег"), .author = -102, .created = "2003-01-02", .moved = "", .tags = T("стихи"), .text = T("снег на подоконнике —\nкот смотрит на него\nкак на чужого") },
    .{ .id = 3, .title = T("Ещё один фрагмент"), .author = -101, .created = "2003-06-01", .moved = "", .tags = T("проза"), .text = T("Дальнобойщики говорят о погоде так, как другие говорят о боге.") },
    .{ .id = -1, .title = T("О ссылках в цифровых библиотеках"), .author = -102, .created = "2003-03-14", .moved = "", .tags = T("статья"), .text = T("Каждое произведение должно иметь короткий, вечный адрес. Номер — лучшее имя: его не надо транслитерировать.\n\nОтрицательные номера позволяют на одном пространстве держать родственные сущности: стихи и песни, книги и серии, людей и персонажей.") },
    .{ .id = -2, .title = T("Как мы удаляем имиджборды"), .author = 1001, .created = "2003-04-01", .moved = "", .tags = T("статья,сайт"), .text = T("Треды живут ограниченное время. После истечения TTL нить исчезает без следа. Это не баг.") },
};

pub const forums = [_]dbm.Forum{
    .{ .id = 1, .title = T("Общий"), .about = T("Обо всём, что связано с библиотекой.") },
    .{ .id = 2, .title = T("Поэзия"), .about = T("Обсуждение стихов, верлибров и бардовской песни.") },
    .{ .id = 3, .title = T("Мастерская"), .about = T("Черновики, критика, взаимопомощь.") },
};
pub const topics = [_]dbm.Topic{
    .{ .id = 1, .forum = 1, .title = T("Добро пожаловать") },
    .{ .id = 2, .forum = 2, .title = T("Верлибр — это стихи?") },
};
pub const posts = [_]dbm.Post{
    .{ .id = 1, .topic = 1, .forum = 1, .author = 1001, .date = "2003-01-01", .text = T("Правила простые: уважайте друг друга.") },
    .{ .id = 2, .topic = 1, .forum = 1, .author = 1002, .date = "2003-01-02", .text = T("Спасибо, уютно.") },
    .{ .id = 3, .topic = 2, .forum = 2, .author = -101, .date = "2003-04-04", .text = T("Да. Следующий вопрос.") },
};

pub const boards = [_]dbm.Board{
    .{ .id = "b", .title = T("Бред"), .ttl_min = 60 },
    .{ .id = "lit", .title = T("Литература"), .ttl_min = 24 * 60 },
    .{ .id = "mu", .title = T("Музыка"), .ttl_min = 6 * 60 },
};
pub const ib_subj = T("Первый нах");
pub const ib_text1 = T("Тред удалится через час. Пишите быстрее.");
pub const ib_text2 = T(">>1\nне успеем");
pub const anon = T("Аноним");

/// Записывает заготовку в пустое хранилище. Снимок после этого надо собрать
/// заново (сервер при старте соберёт его сам, если снимка ещё нет).
pub fn seed(a: std.mem.Allocator, l: *L.Ledger, now_ms: i64) void {
    const d = dbm.Db{ .l = l, .s = undefined, .a = a };
    for (persons) |p| l.put(L.key(a, "H", .{p.id}), L.rec(a, .{ p.name, p.years, p.about }));
    for (pieces, 1..) |p, seq| l.put(L.key(a, "p", .{p.id}), L.rec(a, .{ p.title, p.author, p.genre, p.year, p.text, p.chords, p.notes, seq }));
    for (users) |u| {
        d.putUser(.{ .id = u.id, .nick = u.nick, .joined = u.joined, .about = u.about, .login = u.login });
        d.putAccount(.{ .login = u.login, .user = u.id, .hash = clipper.auth.hashPassword(a, u.login), .rights = u.rights, .blocked = false });
    }
    for (characters) |p| d.putCharacter(p);
    for (drafts, 1..) |x, seq| {
        var dr = x;
        dr.seq = @intCast(seq);
        d.putDraft(dr);
    }
    l.put("Ndseq", std.fmt.comptimePrint("{d}", .{drafts.len + 1}));
    for (forums) |f| l.put(L.key(a, "F", .{f.id}), L.rec(a, .{ f.title, f.about }));
    for (topics) |t| l.put(L.key(a, "T", .{ t.forum, t.id }), L.rec(a, .{t.title}));
    for (posts) |p| d.putPost(p);
    for (boards) |bd| l.put(L.key(a, "B", .{bd.id}), L.rec(a, .{ bd.title, bd.ttl_min }));
    d.putIbPost("b", .{ .no = 1, .thread = 1, .date = now_ms - 5 * 60_000, .name = anon, .subj = ib_subj, .img = "", .img_type = "", .text = ib_text1 });
    d.putIbPost("b", .{ .no = 2, .thread = 1, .date = now_ms - 2 * 60_000, .name = anon, .subj = "", .img = "", .img_type = "", .text = ib_text2 });
    // счётчики номеров — как в макете
    inline for (.{ .{ "draft", 4 }, .{ "draftNeg", -3 }, .{ "piece", 6 }, .{ "post", 4 }, .{ "topic", 3 }, .{ "ib", 3 }, .{ "user", 1003 }, .{ "authorNeg", -103 }, .{ "quote", 1 }, .{ "bookmark", 1 }, .{ "character", -6 } }) |kv| {
        l.put("N" ++ kv[0], std.fmt.comptimePrint("{d}", .{kv[1]}));
    }
}

/// Папка библиотеки с заготовкой: хранилище записано и закрыто, снимка нет —
/// его соберёт App.init.
pub fn prepare(gpa: std.mem.Allocator, root: []const u8, btree: bool) !void {
    var dir = try std.fs.cwd().makeOpenPath(root, .{});
    defer dir.close();
    var l = try L.Ledger.open(gpa, dir, if (btree) .btree else .journal);
    defer l.close();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    seed(arena.allocator(), &l, clipper.sys.nowMs());
    try l.flush();
}
