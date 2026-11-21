// Гонки между воркерами (-w N): много посетителей пишут одновременно, каждый
// запрос — по новому соединению, то есть попадает к случайному воркеру.
//
//   zig build fixture -- ПАПКА [-btree] && clipper -p 3911 -r ПАПКА -w 4 [-btree]
//   node test/workers/run.mjs localhost 3911 [ПОСЕТИТЕЛЕЙ=12] [ЗАПИСЕЙ=8]
//
// Проверяется: новые номера не повторяются, ничего не теряется, записанное
// одним воркером сразу видно у другого (страница, сеанс, новая книга), общие
// счётчики складываются. С `-w 1` тест тоже обязан проходить.

import http from "node:http";

const [host, portS, usersS, perS] = process.argv.slice(2);
const port = +portS, USERS = +(usersS || 12), PER = +(perS || 8);
if (!host || !port) { console.error("usage: node run.mjs HOST PORT [ПОСЕТИТЕЛЕЙ] [ЗАПИСЕЙ]"); process.exit(2); }
const run = Date.now().toString(36).slice(-5);

/** Один запрос по новому соединению. */
function request(method, path, { cookie = "", body = null } = {}) {
  return new Promise((resolve, reject) => {
    const headers = { connection: "close" };
    if (cookie) headers.cookie = cookie;
    if (body != null) { headers["content-type"] = "application/x-www-form-urlencoded"; headers["content-length"] = Buffer.byteLength(body); }
    const req = http.request({ host, port, method, path, headers, agent: false }, res => {
      const chunks = [];
      res.on("data", d => chunks.push(d));
      res.on("end", () => resolve({ status: res.statusCode, loc: res.headers.location || "", cookies: res.headers["set-cookie"] || [], body: Buffer.concat(chunks).toString("latin1") }));
    });
    req.on("error", reject);
    req.setTimeout(30000, () => req.destroy(new Error("нет ответа 30 с: " + method + " " + path)));
    if (body != null) req.write(body);
    req.end();
  });
}

class Visitor {
  constructor(login) { this.login = login; this.jar = new Map(); }
  take(r) { for (const c of r.cookies) { const kv = c.split(";")[0], i = kv.indexOf("="); this.jar.set(kv.slice(0, i), kv.slice(i + 1)); } return r; }
  get cookie() { return [...this.jar].map(([k, v]) => k + "=" + v).join("; "); }
  async get(path) { return this.take(await request("GET", path, { cookie: this.cookie })); }
  async post(path, fields) {
    if (!this.jar.has("csrf")) await this.get("/signin");
    const body = [...fields, ["_csrf", this.jar.get("csrf")]].map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&");
    return this.take(await request("POST", path, { cookie: this.cookie, body }));
  }
}

let fails = 0, total = 0;
function check(name, ok, detail = "") {
  total++;
  if (ok) console.log("ok   " + name);
  else { fails++; console.log("FAIL " + name + (detail ? " — " + detail : "")); }
}
const idOf = loc => { const m = /^\/[a-z]\/(-?\d+)/.exec(loc); return m ? +m[1] : null; };
const dups = list => list.filter((x, i) => list.indexOf(x) !== i);
const viewsNow = async () => { const r = await request("GET", "/x/site/views"); try { return +JSON.parse(r.body).value || +JSON.parse(r.body).message || 0; } catch { return -1; } };

const views0 = await viewsNow();

// 1. регистрация: все сразу; половина — авторы (им можно выкладывать книги)
const visitors = Array.from({ length: USERS }, (_, i) => new Visitor(`w${run}_${i}`));
const signed = await Promise.all(visitors.map((v, i) => v.post("/signup", [["login", v.login], ["pass", "pass" + i], ["nick", v.login], ["kind", i % 2 ? "author" : "user"]])));
check(`регистрация: ${USERS} участников одновременно`, signed.every(r => r.status === 303 && r.loc.startsWith("/panel")), signed.map(r => r.status).join(","));
// сеанс, начатый одним воркером, действует у остальных
const panels = await Promise.all(visitors.flatMap(v => [v.get("/panel"), v.get("/panel"), v.get("/panel")]));
check("сеанс виден всем воркерам", panels.every(r => r.status === 200), panels.map(r => r.status).join(","));
const uids = panels.filter((_, i) => i % 3 === 0).map(r => /\/u\/(-?\d+)/.exec(r.body)?.[1]);
check("номера участников не повторяются", uids.every(Boolean) && dups(uids).length === 0, "повторы: " + dups(uids).join(","));

// 2. черновики: каждый пишет PER штук подряд, все посетители — одновременно;
// сразу после записи страницу читает другое соединение
const drafts = [];
await Promise.all(visitors.map(async v => {
  for (let k = 0; k < PER; k++) {
    const title = `T-${v.login}-${k}`;
    const r = await v.post("/d", [["kind", k % 3 ? "draft" : "article"], ["title", title], ["text", "text " + title]]);
    const page = r.status === 303 ? await v.get(r.loc) : { status: 0, body: "" };
    drafts.push({ title, status: r.status, id: idOf(r.loc), seen: page.status === 200 && page.body.includes(title) });
  }
}));
check(`черновики: ${USERS * PER} записей приняты`, drafts.every(d => d.status === 303 && d.id), drafts.filter(d => d.status !== 303).map(d => d.status).join(","));
const dids = drafts.map(d => d.id);
check("номера черновиков не повторяются", dups(dids).length === 0, "повторы: " + [...new Set(dups(dids))].join(","));
check("запись сразу видна по новому соединению", drafts.every(d => d.seen), drafts.filter(d => !d.seen).length + " не видны");
// ничего не потеряно и не перепутано: каждая страница показывает свой заголовок
const reread = await Promise.all(drafts.map(d => request("GET", "/d/" + d.id, { cookie: visitors[0].cookie })));
check("каждый номер ведёт к своей записи", reread.every((r, i) => r.status === 200 && r.body.includes(drafts[i].title)), reread.filter((r, i) => !(r.status === 200 && r.body.includes(drafts[i].title))).length + " чужих или пропавших");

// 3. книги: авторы выкладывают одновременно — снимок каталога пересобирается
// под блокировкой, новая книга сразу открывается у любого воркера
const authors = visitors.filter((_, i) => i % 2);
const books = await Promise.all(authors.map(async v => {
  const title = `Book-${v.login}`;
  const r = await v.post("/b/upload", [["title", title], ["about", "a"], ["text", "## One\n\nfirst " + title + "\n\n## Two\n\nsecond"]]);
  const id = idOf(r.loc);
  const pages = id ? await Promise.all([request("GET", "/b/" + id), request("GET", "/b/" + id + "/1"), request("GET", "/b/" + id + "/2")]) : [];
  return { title, status: r.status, id, ok: pages.length === 3 && pages.every(p => p.status === 200) && pages[0].body.includes(title) && pages[1].body.includes("first " + title) };
}));
check(`книги: ${authors.length} выложены одновременно`, books.every(b => b.status === 303 && b.id), books.map(b => b.status).join(","));
check("номера книг не повторяются", dups(books.map(b => b.id)).length === 0, books.map(b => b.id).join(","));
check("новая книга сразу читается у любого воркера", books.every(b => b.ok), books.filter(b => !b.ok).map(b => b.id).join(","));
const catalog = await Promise.all(Array.from({ length: 8 }, () => request("GET", "/b")));
check("каталог у всех воркеров содержит все новые книги", catalog.every(r => books.every(b => r.body.includes(b.title))));

// 4. комментарии и форум вперемешку: номера внутри книги и темы
const comments = await Promise.all(visitors.map(v => v.post("/b/0/comment", [["text", "c-" + v.login]])));
check("комментарии приняты", comments.every(r => r.status === 303), comments.map(r => r.status).join(","));
const book2 = await request("GET", "/b/0", { cookie: visitors[0].cookie });
check("все комментарии на странице книги", visitors.every(v => book2.body.includes("c-" + v.login)));
const cids = [...new Set(comments.map(r => r.loc))];
check("у каждого комментария свой адрес", cids.length === comments.length, comments.map(r => r.loc).join(" "));

// 5. выход у одного воркера закрывает сеанс у всех
const v0 = visitors[0];
const sid = v0.cookie; // прежний cookie: проверяется, что сеанс закрыт в хранилище, а не только забыт браузером
await v0.post("/logout", [["hid", "*"]]);
const after = await Promise.all(Array.from({ length: 6 }, () => request("GET", "/panel", { cookie: sid })));
check("выход действует на всех воркерах", after.every(r => r.status === 303), after.map(r => r.status).join(","));

// 6. счётчик просмотров: каждый воркер считает у себя и раз в 5 с прибавляет к общему
const N = 400;
for (let i = 0; i < N; i += 40) await Promise.all(Array.from({ length: 40 }, () => request("GET", "/help")));
await new Promise(r => setTimeout(r, 12000));
const seen = Math.max(...await Promise.all(Array.from({ length: 12 }, viewsNow)));
check(`просмотры складываются (было ${views0}, стало ${seen}, запросов не меньше ${N})`, views0 >= 0 && seen >= views0 + N);

console.log(`\n${total - fails}/${total} проверок пройдено` + (fails ? `, провалов: ${fails}` : ""));
process.exit(fails ? 1 : 0);
