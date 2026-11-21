// Проверка паритета: один набор HTTP-кейсов прогоняется против макета (Bun)
// и против Zig-сервера; совпадать должны коды ответов, переадресации и текст
// страниц (разметка без тегов и пробелов).
//
//   node test/contract/run.mjs http://localhost:3917 http://localhost:3911 [-v]
//
// Первый адрес — макет, второй — clipper. Оба должны быть только что запущены
// на свежих данных (макет держит данные в памяти). В программе clipper данных нет:
// папку готовит тестовая заготовка — те же записи, что у макета:
//
//   zig build fixture -- ПАПКА && clipper -p 3911 -r ПАПКА

const [mock, zig] = process.argv.slice(2);
const verbose = process.argv.includes("-v");
if (!mock || !zig) { console.error("usage: node run.mjs MOCK_URL ZIG_URL [-v]"); process.exit(2); }

// GET-кейсы: путь; `text: false` — сравнивать только код и тип.
const GET = [
  "/", "/help", "/s", "/s?q=Тамань", "/s?q=чайник", "/s?q=нетакого",
  "/p", "/p/1", "/p/2", "/p/4", "/p/-1", "/p/-2", "/p/0", "/p/99", "/p/1/2", "/p/abc", "/p/01",
  "/b", "/b/1", "/b/2", "/b/3", "/b/4", "/b/-1", "/b/-2", "/b/-9", "/b/99", "/b/2/1", "/b/2/3", "/b/2/4", "/b/2/0",
  "/b/-1/1", "/b/2/-1", "/b/2/-2", "/b/2/-3", "/b/2/-1-2", "/b/2/-1-1", "/b/2/-3-2", "/b/2/-2-1", "/b/2/-9", "/b/1/-1", "/b/2/x", "/b/2/1/2",
  "/q", "/q/2", "/q/2?ch=2", "/q/2?ch=99", "/q/-1", "/q/0", "/q/99",
  "/c", "/c/1", "/c/2", "/c/3", "/c/-1", "/c/-2", "/c/-5", "/c/-101", "/c/99", "/c/2?op=ехал&sz=1", "/c/2?op=нет", "/c/-2?ed=городишко",
  "/d", "/d/1", "/d/2", "/d/-1", "/d/-2", "/d/0", "/d/9", "/d/1/2",
  "/f", "/f/1", "/f/2", "/f/3", "/f/9", "/f/1?topic=1", "/f/2?topic=2", "/f/1?topic=9", "/f/lit", "/f/mu", "/f/zz", "/f/lit?th=5", "/f/toolongname", "/f/1/2",
  "/u", "/u/0", "/u/1001", "/u/1002", "/u/-101", "/u/-102", "/u/5", "/u/1001/2",
  "/signin", "/signin?back=/b/2", "/signup", "/logout", "/panel", "/bookmarks", "/b/upload",
  "/e", "/e/b/2", "/e/b/2?ch=3", "/e/b/99", "/e/p/2", "/e/p/-1", "/e/c/2", "/e/c/-3?op=Зри&sz=2", "/e/c/2?op=ехал&ed=из", "/e/d/-1", "/e/d/1", "/e/u/-101", "/e/u/9", "/e/f/1", "/e/f/3", "/e/banner", "/e/banner?size=468", "/e/zz",
  "/nope", "/a/b/c/d/e/f/g/h",
  "/?t=samlib", "/?t=proza", "/?t=nepomn", "/?t=nepomn&m=true", "/?m=true", "/?t=samlib-dark&m=false", "/b/2?t=nepomn", "/b/2/1?t=proza&m=true", "/c?t=samlib", "/help?t=dark",
  "/theme", "/theme?url=/b/2&t=samlib", "/theme?url=//evil.example&t=proza-dark", "/theme?url=/b/2%3Ft%3Dsamlib&t=nepomn-time&m=true",
];
// Страницы, чей текст зависит от времени или счётчиков: только код.
const CODE_ONLY = [
  // Книга 0 у сервера другая — «Изнанка Клиппера» (.t9n/ru/src/book0), у макета — короткая справка:
  // совпадать должны только коды. /b/0/99 — страницы с таким номером нет ни там, ни там.
  "/b/0", "/b/0/1", "/b/0/7", "/b/0/99", "/e/b/0", "/x/b/chapters?id=0&label=Главы",
  "/f/b", "/f/b?th=1", "/f/b?th=77", "/e/stat",
  "/x/b/reads.svg?id=2", "/x/b/comments.png?id=2", "/x/u/books.svg?id=-101&color=blue", "/x/site/users", "/x/s/p.svg?label=poems&color=maroon", "/x/b/reads?id=99", "/x/zz/reads", "/x/b/zz?id=2", "/x/b/reads.gif?id=2",
  "/b/2/txt", "/b/2/fb2", "/b/2/epub", "/b/0/txt", "/b/99/txt", "/b/-1/txt",
  "/favicon.ico", "/logo64.png", "/logo96.png", "/logo120.png", "/g/91/83a5c9-abcbef.bmp", "/g/0/83a5c9.bmp", "/g/20/zz.bmp", "/img/000000000000", "/files/nope.txt", "/files/../ADMIN.env",
];
// Точное содержимое JSON бейджей.
const JSON_CASES = ["/x/b/comments?id=2", "/x/b/chapters?id=2", "/x/u/books?id=-101", "/x/p/lines?id=4", "/x/c/quotes?id=-2", "/x/f/topics?id=1", "/x/s/b", "/x/s/p", "/x/s/d", "/x/s/f", "/x/s/u", "/x/site/books"];

function textOf(html) {
  // Только тело, без скриптов и стилей; теги и пробелы не считаются.
  let s = html.replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<style[\s\S]*?<\/style>/gi, "");
  const b = s.search(/<body/i); if (b >= 0) s = s.slice(b);
  // значения, которые у каждого посетителя свои
  // форматы загрузки: у макета все пять, у clipper PDF и DjVu — только с флагами -pdf и -djvu
  s = s.replace(/name="_csrf" value="[^"]*"/g, "").replace(/или файл \.txt.*?можно задать своё\.(?: PDF и DjVu — только с текстом внутри: сканы не распознаются\.)?/, "или файл .txt");
  // у clipper — сайт, а не макет: «официальный макет» (nepomn), «макет» в подвалах и строка о тестовых учётках убраны
  s = s.replace(/<h5 class="sitestatus">официальный<br>макет<\/h5>/g, "").replace(/ · макет · /g, " · ").replace(/ — макет\. /g, ". ")
    .replace(/\s*<p class="muted">Тестовые учётные записи макета перечислены в README\.<\/p>/g, "");
  // стихи от имени автора (BACKLOG_RU.md §20): у макета этого нет
  s = s.replace(/<p><a href="[^"]*\/p\/new[^"]*">Выложить стих или песню<\/a>[^<]*<\/p>/g, "")
    .replace(/<p><a href="[^"]*\/p\/-?\d+\/edit[^"]*">Править или удалить<\/a><\/p>/g, "")
    .replace(/<div class="muted">Выложил: .*?<\/div>/g, "")
    .replace(/<form action="\/u\/-?\d+\/authors"[\s\S]*?<\/form>/g, "")
    .replace(/<p>(Автор на сайте|Это участник сайта): .*?<\/p>/g, "");
  s = s.replace(/<[^>]*>/g, " ");
  s = s.replace(/&nbsp;|&#160;/g, " ").replace(/&laquo;/g, "«").replace(/&raquo;/g, "»").replace(/&mdash;/g, "—").replace(/&hellip;/g, "…").replace(/&uarr;/g, "↑")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  s = s.replace(/\s+/g, " ").trim();
  // книга 0: у макета справка «Клиппер: как устроен сайт» 2003 года, у сервера — «Изнанка Клиппера»; автор у обоих /u/0
  return s.replace(/(Клиппер: как устроен сайт|Изнанка Клиппера)( admin)?( 20\d\d)?/g, "«книга 0»");
}
// Ссылки страницы: пути с параметрами (порядок параметров не важен).
function unpercent(s, legacy) {
  const bytes = [];
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "%" && /^[0-9a-f]{2}$/i.test(s.slice(i + 1, i + 3))) { bytes.push(parseInt(s.slice(i + 1, i + 3), 16)); i += 2; }
    else if (s[i] === "+") bytes.push(32);
    else bytes.push(...new TextEncoder().encode(s[i]));
  }
  const u8 = new Uint8Array(bytes);
  if (legacy) { try { return new TextDecoder("utf-8", { fatal: true }).decode(u8); } catch {} return new TextDecoder("windows-1251").decode(u8); }
  return new TextDecoder().decode(u8);
}
function linksOf(html, legacy) {
  const out = new Set();
  for (const m of html.matchAll(/(?:href|src|action)=["']([^"']*)["']/g)) {
    let u = m[1].replace(/&amp;/g, "&").replace(/&#39;/g, "'").replace(/&quot;/g, '"');
    if (!u.startsWith("/") || u.startsWith("/css/") || u.startsWith("/g/")) continue;
    // макет дописывает t/m после «#…» (и они теряются) — сравниваем по смыслу
    const bad = /^([^#?]*)(#[^?]*)\?(.*)$/.exec(u); if (bad) u = bad[1] + "?" + bad[3] + bad[2];
    const hi = u.indexOf("#"), hash = hi >= 0 ? u.slice(hi) : ""; if (hi >= 0) u = u.slice(0, hi);
    const qi = u.indexOf("?"), path = qi >= 0 ? u.slice(0, qi) : u, query = qi >= 0 ? u.slice(qi + 1) : "";
    const q = query.split("&").filter(Boolean).map(p => { const e = p.indexOf("="); return unpercent(e >= 0 ? p.slice(0, e) : p, legacy) + "=" + unpercent(e >= 0 ? p.slice(e + 1) : "", legacy); }).sort().join("&");
    out.add(unpercent(path, legacy) + (q ? "?" + q : "") + hash);
  }
  return [...out].sort();
}

async function fetchOne(base, path, init = {}) {
  const r = await fetch(base + encodeURI(path).replace(/%25/g, "%"), { redirect: "manual", ...init });
  const buf = new Uint8Array(await r.arrayBuffer());
  const ct = r.headers.get("content-type") || "";
  const cs = /charset=([\w-]+)/i.exec(ct)?.[1] || "utf-8";
  let body = "";
  try { body = new TextDecoder(cs).decode(buf); } catch { body = new TextDecoder().decode(buf); }
  body = body.split(base).join("http://ORIGIN");
  let loc = r.headers.get("location") || "";
  if (loc.startsWith(base)) loc = loc.slice(base.length);
  // порядок параметров переадресации не важен
  if (loc.includes("?")) { const [p, q] = loc.split("?"); const [qq, h] = q.split("#"); loc = p + "?" + qq.split("&").map(x => { try { return decodeURIComponent(x); } catch { return x; } }).sort().join("&") + (h ? "#" + h : ""); }
  return { status: r.status, type: ct.split(";")[0], loc, body, bytes: buf.length, cookies: r.headers.getSetCookie?.() || [] };
}

// На windows-1251 страницах формы уходят в windows-1251; макет ждёт UTF-8.
const CP = "ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—\u0098™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї°±Ііґµ¶·ё№є»јЅѕї";
function cp1251(s) {
  const out = [];
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c < 128) out.push(c);
    else if (c >= 0x410 && c <= 0x44f) out.push(c - 0x410 + 0xc0);
    else { const i = CP.indexOf(ch); out.push(i >= 0 ? 0x80 + i : 63); }
  }
  return out;
}
function formBody(fields, legacy) {
  return fields.map(([k, v]) => {
    const bytes = legacy ? cp1251(String(v)) : [...new TextEncoder().encode(String(v))];
    return encodeURIComponent(k) + "=" + bytes.map(b => (/[A-Za-z0-9_.~-]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : b === 32 ? "+" : "%" + b.toString(16).toUpperCase().padStart(2, "0"))).join("");
  }).join("&");
}

/** Посетитель одного сервера: хранит cookies, умеет GET и POST с CSRF. */
class Client {
  constructor(base, legacy) { this.base = base; this.legacy = legacy; this.jar = new Map(); }
  take(r) { for (const c of r.cookies) { const [kv] = c.split(";"); const i = kv.indexOf("="); const k = kv.slice(0, i), v = kv.slice(i + 1); if (v === "" || /Max-Age=0/i.test(c)) this.jar.delete(k); else this.jar.set(k, v); } return r; }
  headers() { return this.jar.size ? { cookie: [...this.jar].map(([k, v]) => k + "=" + v).join("; ") } : {}; }
  async get(path) { return this.take(await fetchOne(this.base, path, { headers: this.headers() })); }
  async post(path, fields, { csrf = true } = {}) {
    if (!this.jar.has("csrf")) await this.get("/signin");
    const all = csrf ? [...fields, ["_csrf", this.jar.get("csrf")]] : fields;
    return this.take(await fetchOne(this.base, path, { method: "POST", headers: { ...this.headers(), "content-type": "application/x-www-form-urlencoded" }, body: formBody(all, this.legacy) }));
  }
}

let fails = 0, total = 0;
function check(name, a, b, what) {
  total++;
  if (a === b) { if (verbose) console.log("ok   " + name + " " + what); return true; }
  fails++;
  console.log("FAIL " + name + " — " + what);
  const show = x => String(x).length > 300 ? String(x).slice(0, 300) + "…" : String(x);
  if (typeof a === "string" && typeof b === "string" && a.length > 120) {
    let i = 0; while (i < a.length && a[i] === b[i]) i++;
    console.log("     макет:   …" + show(a.slice(Math.max(0, i - 60), i + 160)));
    console.log("     clipper: …" + show(b.slice(Math.max(0, i - 60), i + 160)));
  } else { console.log("     макет:   " + show(a)); console.log("     clipper: " + show(b)); }
  return false;
}
// Возможности clipper, которых у макета нет (BACKLOG_RU.md §21): удаление черновиков и цитаты из статей.
function stripNew(html) {
  let s = html.replace(/<form action="\/d\/-?\d+\/delete"[\s\S]*?<\/form>/g, "");
  // раздел /v (BACKLOG_RU.md §22): пункт меню, плитка главной, ссылки «загрузить» у книг и стихов, привязка к чтецам
  s = s.replace(/<td[^>]*class="box"><a href="\/v(?:\?[^"]*)?"><b>Записи<\/b><\/a><br><span class="muted">[^<]*<\/span><\/td>/g, "")
    .replace(/<li>&raquo; <a href="\/v(?:\?[^"]*)?"[^>]*>Записи<\/a><\/li>/g, "")
    .replace(/<li class="menu"><a class="menu" href="\/v(?:\?[^"]*)?"[^>]*>Записи<\/a><\/li>/g, "")
    .replace(/ ?\[<a href="\/v(?:\?[^"]*)?"[^>]*>Записи<\/a>\]/g, "")
    .replace(/(?:<br>)?<a href="\/v(?:\?[^"]*)?"[^>]*>Записи<\/a>/g, "")
    .replace(/<p><a href="\/v\/new\?(?:book|piece)=[^"]*">Загрузить (?:аудиокнигу|исполнение)<\/a><\/p>/g, "")
    .replace(/<form action="\/u\/-?\d+\/readers"[\s\S]*?<\/form>/g, "");
  // профили (BACKLOG_RU.md §21): своя страница участник правит сам
  s = s.replace(/<p><a href="\/u\/-?\d+\/edit[^"]*">Править профиль<\/a><\/p>/g, "");
  s = s.replace(/Сайтом управляет только встроенный администратор \/u\/0\.|Сайтом управляют сотрудники и \/u\/0\./g, "«кто управляет сайтом»");
  if (/action="\/[dp]\/-?\d+\/mark"/.test(s)) {
    s = s.replace(/<div id="cmenu"[\s\S]*?<\/div>/g, "").replace(/<form id="cf-quote"[\s\S]*?<\/form>/g, "")
      .replace(/<div class="box nojs">[\s\S]*?<\/form><\/div>/g, "").replace(/<p class="muted hint">[\s\S]*?<\/p>/g, "");
  }
  return s;
}
function same(name, m0, z0, opts = {}) {
  // страница автора (/c/N, N > 0: у макета — фильтр цитат) у clipper своя — только код ответа
  if (typeof m0.body === "string" && /<form action="\/c\/[1-9]\d*" method="get"/.test(m0.body)) opts = { ...opts, text: false };
  const { text = true, links = true } = opts;
  const m = { ...m0, body: typeof m0.body === "string" ? stripNew(m0.body) : m0.body };
  const z = { ...z0, body: typeof z0.body === "string" ? stripNew(z0.body) : z0.body };
  check(name, m.status, z.status, "код ответа");
  check(name, m.loc, z.loc, "переадресация");
  if (m.status !== 303) check(name, m.type, z.type, "тип содержимого");
  if (text && m.type === "text/html") {
    check(name, textOf(m.body), textOf(z.body), "текст страницы");
    if (links) {
      const a = linksOf(m.body, false), b = linksOf(z.body, true);
      check(name, a.filter(x => !b.includes(x)).join(" | "), b.filter(x => !a.includes(x)).join(" | "), "ссылки страницы (есть только у одного)");
    }
  }
}

// ---------- 1. чтение ----------
// страница автора /c/N у clipper своя: стихи, книги, профиль вместо цитат (BACKLOG_RU.md §21) — только код ответа
for (const p of GET) same("GET " + p, await fetchOne(mock, p), await fetchOne(zig, p), /^\/c\/\d/.test(p) ? { text: false } : undefined);
for (const p of CODE_ONLY) same("GET " + p, await fetchOne(mock, p), await fetchOne(zig, p), { text: false });
for (const p of JSON_CASES) {
  const m = await fetchOne(mock, p), z = await fetchOne(zig, p);
  check("GET " + p, m.status, z.status, "код ответа");
  if (m.status === 200) check("GET " + p, JSON.stringify(JSON.parse(m.body)), JSON.stringify(JSON.parse(z.body)), "JSON");
}

// ---------- 2. сценарии прав: гость / читатель / автор ----------
const pair = () => [new Client(mock, false), new Client(zig, true)];
async function both(cl, name, fn, opt) { const m = await fn(cl[0]), z = await fn(cl[1]); same(name, m, z, opt); return [m, z]; }

{ // гость
  const g = pair();
  await both(g, "гость: POST без CSRF", c => c.post("/d", [["title", "x"]], { csrf: false }));
  await both(g, "гость: черновик запрещён", c => c.post("/d", [["title", "x"], ["text", "y"]]));
  await both(g, "гость: комментарий запрещён", c => c.post("/b/2/comment", [["text", "привет"]]));
  await both(g, "гость: форум запрещён", c => c.post("/f/1/topic", [["title", "t"], ["text", "x"]]));
  await both(g, "гость: выкладывание запрещено", c => c.post("/b/upload", [["title", "t"], ["text", "x"]]));
  await both(g, "гость: отметка → вход", c => c.post("/b/2/1/mark", [["kind", "bookmark"], ["para", "0"], ["text", "Я ехал"]]));
  await both(g, "гость: закладки → вход", c => c.post("/bookmarks/del", [["id", "1"]]));
  await both(g, "гость: панель → вход", c => c.post("/panel/features", []));
  await both(g, "гость: персонаж → вход", c => c.post("/c/new", [["name", "Икс"], ["author", "1"]]));
  await both(g, "гость: неверный пароль", c => c.post("/signin", [["login", "reader"], ["pass", "nope"]]));
  await both(g, "гость: доска — пустой пост", c => c.post("/f/lit/post", [["name", ""], ["text", ""]]));
  await both(g, "гость: доска — нет такой", c => c.post("/f/zz/post", [["text", "x"]]));
  await both(g, "гость: POST в никуда", c => c.post("/nope", []));
  await both(g, "гость: t переживает POST", c => c.post("/signin", [["login", "x"], ["pass", "y"], ["t", "samlib"]]));
}
{ // читатель
  const r = pair();
  await both(r, "читатель: вход", c => c.post("/signin", [["login", "reader"], ["pass", "reader"], ["back", "/b/2"]]));
  await both(r, "читатель: главная", c => c.get("/"));
  await both(r, "читатель: панель", c => c.get("/panel"), { links: true });
  await both(r, "читатель: закладки", c => c.get("/bookmarks"));
  await both(r, "читатель: страница чтения", c => c.get("/b/2/1"));
  await both(r, "читатель: выкладывание запрещено", c => c.post("/b/upload", [["title", "t"], ["text", "x"]]));
  await both(r, "читатель: страница выкладывания", c => c.get("/b/upload"));
  await both(r, "читатель: новый черновик", c => c.post("/d", [["kind", "draft"], ["title", "Мой черновик"], ["text", "первая строка\nвторая\n\nновый абзац"], ["tags", "проза, тест ,"]]));
  await both(r, "читатель: черновик виден", c => c.get("/d/4"));
  await both(r, "читатель: новая статья", c => c.post("/d", [["kind", "article"], ["title", ""], ["text", ""]]));
  await both(r, "читатель: статья видна", c => c.get("/d/-3"));
  await both(r, "читатель: комментарий", c => c.post("/b/2/comment", [["text", "Новый комментарий <b>"]]));
  await both(r, "читатель: ответ на ответ уходит в корень", c => c.post("/b/2/comment", [["text", "ответ"], ["parent", "2"]]));
  await both(r, "читатель: ответ на несуществующий", c => c.post("/b/2/comment", [["text", "ответ"], ["parent", "99"]]));
  await both(r, "читатель: пустой комментарий", c => c.post("/b/2/comment", [["text", "  "]]));
  await both(r, "читатель: книга с комментариями", c => c.get("/b/2"));
  await both(r, "читатель: комментарий -1-5", c => c.get("/b/2/-1-5"));
  await both(r, "читатель: тема форума", c => c.post("/f/3/topic", [["title", "Первая тема"], ["text", "текст"]]));
  await both(r, "читатель: ответ в теме", c => c.post("/f/3/reply", [["topic", "3"], ["text", "ещё"]]));
  await both(r, "читатель: ответ в чужой теме", c => c.post("/f/3/reply", [["topic", "1"], ["text", "ещё"]]));
  await both(r, "читатель: тема видна", c => c.get("/f/3?topic=3"));
  await both(r, "читатель: форум виден", c => c.get("/f/3"));
  await both(r, "читатель: закладка", c => c.post("/b/2/3/mark", [["kind", "bookmark"], ["para", "0"], ["text", "самый   скверный городишко"], ["note", "смешно"]]));
  await both(r, "читатель: цитата автору", c => c.post("/b/2/2/mark", [["kind", "quote"], ["para", "0"], ["text", "я живо проскакал"], ["person", "2"]]));
  await both(r, "читатель: цитата персонажу", c => c.post("/b/2/2/mark", [["kind", "quote"], ["para", "0"], ["text", "Терекское и Дарьяльское ущелья"], ["person", "-3"]]));
  await both(r, "читатель: цитата-дубль", c => c.post("/b/2/2/mark", [["kind", "quote"], ["para", "0"], ["text", "я живо проскакал"], ["person", "2"]]));
  await both(r, "читатель: цитата чужому персонажу", c => c.post("/b/2/2/mark", [["kind", "quote"], ["para", "0"], ["text", "Расставшись"], ["person", "-1"]]));
  await both(r, "читатель: текста нет в абзаце", c => c.post("/b/2/2/mark", [["kind", "quote"], ["para", "0"], ["text", "нет такого текста"], ["person", "2"]]));
  await both(r, "читатель: нет абзаца", c => c.post("/b/2/2/mark", [["kind", "bookmark"], ["para", "7"], ["text", "x"]]));
  await both(r, "читатель: нет страницы", c => c.post("/b/2/9/mark", [["kind", "bookmark"], ["para", "0"], ["text", "x"]]));
  await both(r, "читатель: отметки в тексте", c => c.get("/b/2/2"));
  await both(r, "читатель: отметки в тексте 3", c => c.get("/b/2/3"));
  await both(r, "читатель: цитаты автора", c => c.get("/c/2"));
  await both(r, "читатель: цитаты персонажа", c => c.get("/c/-3"));
  await both(r, "читатель: закладки с новой", c => c.get("/bookmarks"));
  await both(r, "читатель: примечание", c => c.post("/bookmarks/note", [["id", "2"], ["note", "другое"]]));
  await both(r, "читатель: чужая закладка", c => c.post("/bookmarks/del", [["id", "77"]]));
  await both(r, "читатель: удалить закладку", c => c.post("/bookmarks/del", [["id", "2"]]));
  await both(r, "читатель: персонаж", c => c.post("/c/new", [["name", "Вернер"], ["author", "2"], ["book", "2"], ["book", "1"], ["about", "Доктор."]]));
  await both(r, "читатель: персонаж-дубль", c => c.post("/c/new", [["name", "вернер"], ["author", "2"]]));
  await both(r, "читатель: персонаж без имени", c => c.post("/c/new", [["name", ""], ["author", "2"]]));
  await both(r, "читатель: персонаж без автора", c => c.post("/c/new", [["name", "Икс"], ["author", "77"]]));
  await both(r, "читатель: привязка к книгам", c => c.post("/c/-6/books", []));
  await both(r, "читатель: персонаж виден", c => c.get("/c/-6"));
  await both(r, "читатель: профиль", c => c.post("/panel/profile", [["nick", "Читатель"], ["about", "О себе"], ["pass", ""]]));
  await both(r, "читатель: короткий пароль", c => c.post("/panel/profile", [["nick", "Читатель"], ["about", ""], ["pass", "ab"]]));
  await both(r, "читатель: чужая панель", c => c.post("/panel/features", []));
  await both(r, "читатель: нет такой панели", c => c.post("/panel/zzz", []));
  await both(r, "читатель: перенос в стихи чужого черновика", c => c.post("/d/2/piece", [["genre", "верлибр"]]));
  await both(r, "читатель: стих появился", c => c.get("/p/6"));
  await both(r, "читатель: черновик только для чтения", c => c.get("/d/2"));
  await both(r, "читатель: повторный перенос", c => c.post("/d/2/piece", [["genre", "стихи"]]));
  await both(r, "читатель: объединение без отметок", c => c.post("/d/merge", [["title", "Пусто"]]));
  await both(r, "читатель: объединение", c => c.post("/d/merge", [["title", "Мой сборник"], ["id", "1"], ["id", "3"], ["id", "2"], ["id", "-1"]]));
  await both(r, "читатель: книга из черновиков", c => c.get("/b/3"));
  await both(r, "читатель: её страница 2", c => c.get("/b/3/2"));
  await both(r, "читатель: список черновиков", c => c.get("/d"));
  await both(r, "читатель: список книг", c => c.get("/b"));
  await both(r, "читатель: главная после всего", c => c.get("/"));
  await both(r, "читатель: поиск по новому", c => c.get("/s?q=сборник"));
  await both(r, "читатель: выход чужого сеанса", c => c.post("/logout", [["hid", "zzzz"]]), { text: false });
  await both(r, "читатель: выйти везде", c => c.post("/logout", [["hid", "*"]]));
  await both(r, "читатель: после выхода панель → вход", c => c.get("/panel"));
}
{ // автор и регистрация
  const a = pair();
  await both(a, "автор: вход", c => c.post("/signin", [["login", "VETROV"], ["pass", "vetrov"]]));
  await both(a, "автор: страница выкладывания", c => c.get("/b/upload"));
  await both(a, "автор: выкладывание без текста", c => c.post("/b/upload", [["title", "Без текста"], ["text", ""]]));
  await both(a, "автор: выкладывание", c => c.post("/b/upload", [["title", "Третья повесть"], ["annotation", "Про дорогу."], ["text", "вступление\n\nвторой абзац\n## Глава первая\nтекст первой\n## Вторая\nтекст второй"], ["embed", "1"]]));
  await both(a, "автор: книга видна", c => c.get("/b/4"));
  await both(a, "автор: глава 2", c => c.get("/b/4/2"));
  await both(a, "автор: глава 3", c => c.get("/b/4/3"));
  await both(a, "автор: панель с книгами", c => c.get("/panel"));
  await both(a, "автор: запрет встраивания", c => c.post("/panel/books", [["book", "6"], ["book", "3"], ["embed3", "1"]]));
  await both(a, "автор: iframe запрещён", c => c.get("/e/b/4"));
  await both(a, "автор: iframe разрешён", c => c.get("/e/b/3"));
  const n = pair();
  await both(n, "регистрация: плохой логин", c => c.post("/signup", [["login", "я"], ["pass", "1234"]]));
  await both(n, "регистрация: короткий пароль", c => c.post("/signup", [["login", "newbie"], ["pass", "12"]]));
  await both(n, "регистрация: занято", c => c.post("/signup", [["login", "Reader"], ["pass", "1234"]]));
  await both(n, "регистрация: читатель", c => c.post("/signup", [["login", "newbie"], ["pass", "1234"], ["nick", "Новичок"], ["kind", "user"]]));
  await both(n, "регистрация: панель", c => c.get("/panel"));
  await both(n, "регистрация: профиль", c => c.get("/u/1003"));
  const w = pair();
  await both(w, "регистрация: автор", c => c.post("/signup", [["login", "writer_1"], ["pass", "1234"], ["nick", ""], ["kind", "author"]]));
  await both(w, "регистрация: профиль автора", c => c.get("/u/-103"));
  await both(w, "регистрация: автор может выкладывать", c => c.get("/b/upload"));
  await both(w, "список участников", c => c.get("/u"));
}

console.log(`\n${total - fails}/${total} проверок совпало` + (fails ? `, расхождений: ${fails}` : ""));
process.exit(fails ? 1 : 0);
