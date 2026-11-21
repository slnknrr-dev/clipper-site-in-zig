// Федерация и настройки панели на двух живых серверах.
//
//   clipper -p 3931 -r A -fed -pwd testadmin -pdf -djvu      A: список в файле, новые сайты записываются
//   clipper -p 3932 -r B -fed localhost:3931 -pwd testadmin  B: только сайт A, список во флаге; без -pdf и -djvu
//   node test/fed/run.mjs localhost 3931 3932 testadmin
//
// Обе папки — свежие, с тестовой заготовкой (zig build fixture -- A, то же для B). Проверяется: вход участника A на B по билету (и что
// без разрешения его нет), гость без пароля, одноразовость билета, чужие
// сайты; в панели — оформление и форматы загрузки для сотрудников и прочих;
// PDF и DjVu без флагов запуска не принимаются никем (сайт B).

import http from "node:http";

const [host, portA, portB, adminPass] = process.argv.slice(2);
if (!host || !+portA || !+portB || !adminPass) { console.error("usage: node run.mjs HOST PORT_A PORT_B ПАРОЛЬ_АДМИНИСТРАТОРА"); process.exit(2); }
const nameA = `${host}:${portA}`, nameB = `${host}:${portB}`;
const cp1251 = new TextDecoder("windows-1251");

function request(port, method, path, { cookie = "", body = null, type = "application/x-www-form-urlencoded" } = {}) {
  return new Promise((resolve, reject) => {
    const headers = { connection: "close" };
    if (cookie) headers.cookie = cookie;
    if (body != null) { headers["content-type"] = type; headers["content-length"] = Buffer.byteLength(body); }
    const req = http.request({ host, port, method, path, headers, agent: false }, res => {
      const chunks = [];
      res.on("data", d => chunks.push(d));
      res.on("end", () => {
        const raw = Buffer.concat(chunks);
        const html = (res.headers["content-type"] || "").includes("1251");
        resolve({ status: res.statusCode, loc: res.headers.location || "", cookies: res.headers["set-cookie"] || [], body: html ? cp1251.decode(raw) : raw.toString("utf8") });
      });
    });
    req.on("error", reject);
    req.setTimeout(30000, () => req.destroy(new Error("нет ответа 30 с: " + method + " " + path)));
    if (body != null) req.write(body);
    req.end();
  });
}

class Visitor {
  constructor(port) { this.port = port; this.jar = new Map(); }
  take(r) { for (const c of r.cookies) { const kv = c.split(";")[0], i = kv.indexOf("="); this.jar.set(kv.slice(0, i), kv.slice(i + 1)); } return r; }
  get cookie() { return [...this.jar].map(([k, v]) => k + "=" + v).join("; "); }
  async get(path) { return this.take(await request(this.port, "GET", path, { cookie: this.cookie })); }
  async csrf() { if (!this.jar.has("csrf")) await this.get("/signin"); return this.jar.get("csrf"); }
  async post(path, fields) {
    const body = [...fields, ["_csrf", await this.csrf()]].map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&");
    return this.take(await request(this.port, "POST", path, { cookie: this.cookie, body }));
  }
  async upload(path, fields, file) {
    const b = "----clipperfed" + Date.now();
    const parts = [...fields, ["_csrf", await this.csrf()]].map(([k, v]) => `--${b}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`);
    const head = `--${b}\r\nContent-Disposition: form-data; name="file"; filename="${file.name}"\r\nContent-Type: application/octet-stream\r\n\r\n`;
    const body = Buffer.concat([Buffer.from(parts.join("") + head), file.bytes, Buffer.from(`\r\n--${b}--\r\n`)]);
    return this.take(await request(this.port, "POST", path, { cookie: this.cookie, body, type: "multipart/form-data; boundary=" + b }));
  }
  async signin(login, pass) { return this.post("/signin", [["login", login], ["pass", pass], ["back", "/"]]); }
}

let fails = 0, total = 0;
function check(name, ok, detail = "") {
  total++;
  if (ok) console.log("ok   " + name);
  else { fails++; console.log("FAIL " + name + (detail ? " — " + String(detail).slice(0, 300) : "")); }
}
const msgOf = body => (/<div class="box"><b>([^<]*)<\/b><\/div>/.exec(body) || [])[1] || "";

const adminA = new Visitor(portA), readerA = new Visitor(portA), libA = new Visitor(portA);
check("вход: администратор A", (await adminA.signin("admin", adminPass)).status === 303);
check("вход: reader на A", (await readerA.signin("reader", "reader")).status === 303);
check("вход: librarian на A", (await libA.signin("librarian", "librarian")).status === 303);

// ───────────── федерация ─────────────

let r = await new Visitor(portA).get("/fed");
check("страница /fed открыта гостю", r.status === 200 && r.body.includes("Федерация"));

r = await readerA.post("/fed/out", [["domain", nameB]]);
check("новый сайт: записан, но переход ещё не разрешён (403)", r.status === 403 && msgOf(r.body).includes("пока не разрешил"), r.status + " " + msgOf(r.body));
r = await adminA.get("/panel");
check("панель: новый сайт появился в списке федерации", r.body.includes(`name="fd" value="${nameB}"`));

r = await adminA.post("/panel/fed", [["fd", nameB], [`in_${nameB}`, ""], [`out_${nameB}`, "1"]]);
check("панель: переход на B разрешён", msgOf(r.body) === "Федерация сохранена.", msgOf(r.body));

r = await readerA.post("/fed/out", [["domain", nameB]]);
const m = new RegExp(`^http://${nameB}/fed/in\\?from=${host}%3A${portA}&ticket=([0-9a-f]{32})$`).exec(r.loc);
check("переход: 303 на B/fed/in с билетом", r.status === 303 && !!m, r.status + " " + r.loc);
const inPath = m ? r.loc.slice(`http://${nameB}`.length) : "/fed/in";

const guestB = new Visitor(portB);
r = await guestB.get(inPath);
check("B: гость принят, выдан токен сеанса", r.status === 303 && r.loc === "/" && guestB.jar.has("sid"), r.status + " " + r.loc + " " + msgOf(r.body));
const sidCookie = r.cookies.find(c => c.startsWith("sid=")) || "";
check("B: cookie токена без срока — гаснет с закрытием браузера", !!sidCookie && !/max-age|expires/i.test(sidCookie), sidCookie);
r = await guestB.get("/panel");
check("B: панель гостя — имя с сайтом, пароля нет", r.status === 200 && r.body.includes(`chitatel_77@${nameA}`) && r.body.includes("токене федерации") && !r.body.includes('name="pass"'));
const guestId = (/профиль <a href="\/u\/(\d+)"/.exec(r.body) || [])[1];
r = await new Visitor(portB).get("/u/" + guestId);
check("B: у гостя есть страница участника", r.status === 200 && r.body.includes(`chitatel_77@${nameA}`), guestId);

r = await new Visitor(portB).get(inPath);
check("B: билет одноразовый — второй раз 403", r.status === 403 && msgOf(r.body).includes("не подтвердил вход"), r.status + " " + msgOf(r.body));
r = await new Visitor(portB).signin(`1002@${nameA}`, "");
check("B: гость по паролю не входит (пустой пароль)", r.status === 401);
r = await new Visitor(portB).signin(`1002@${nameA}`, "reader");
check("B: гость по паролю не входит (пароль с A)", r.status === 401);
r = await guestB.post("/fed/out", [["domain", nameA]]);
check("B: гость дальше по федерации не ходит", r.status === 403, r.status);
r = await new Visitor(portB).get("/fed/in?from=evil.example&ticket=" + "0".repeat(32));
check("B: сайт не из списка — 403 без обращения к нему", r.status === 403 && msgOf(r.body).includes("не входит в федерацию"), msgOf(r.body));
r = await new Visitor(portB).get(`/fed/in?from=${nameB}&ticket=` + "0".repeat(32));
check("B: вход «с самого себя» — 400", r.status === 400);
r = await new Visitor(portB).get(`/fed/in?from=${nameA}&ticket=` + "0".repeat(32));
check("B: выдуманный билет — 403", r.status === 403 && msgOf(r.body).includes("не подтвердил вход"), msgOf(r.body));

// второй вход того же участника — тот же гость, не новый
r = await readerA.post("/fed/out", [["domain", nameB]]);
const again = new Visitor(portB);
await again.get(r.loc.slice(`http://${nameB}`.length));
r = await again.get("/panel");
check("B: повторный вход — та же учётная запись гостя", (/профиль <a href="\/u\/(\d+)"/.exec(r.body) || [])[1] === guestId);

// обратное направление: A не разрешал вход с B
const readerB = new Visitor(portB);
await readerB.signin("reader", "reader");
r = await readerB.post("/fed/out", [["domain", nameA]]);
check("B→A: билет выписан (B разрешает в обе стороны)", r.status === 303 && r.loc.startsWith(`http://${nameA}/fed/in?`), r.status + " " + r.loc);
r = await new Visitor(portA).get(r.loc.slice(`http://${nameA}`.length));
check("B→A: A вход с B не разрешал — 403", r.status === 403 && msgOf(r.body).includes("пока не разрешил"), r.status + " " + msgOf(r.body));

r = await request(portA, "GET", "/fed/verify?ticket=" + "0".repeat(32) + "&for=" + nameB);
check("A: /fed/verify на выдуманный билет — error=ticket", r.status === 403 && r.body === "clipper-fed 1\nerror=ticket\n", JSON.stringify(r.body));

// ───────────── оформление ─────────────

r = await adminA.post("/panel/look", [["base", "samlib"], ["mode", "dark"], ["show", "1"], ["b_proza", "1"], ["m_light", "1"]]);
check("панель: оформление сохранено", msgOf(r.body) === "Оформление сохранено.", msgOf(r.body));
r = await new Visitor(portA).get("/");
check("тема и режим по умолчанию — из панели", r.body.includes("/css/samlib-dark.css") && r.body.includes("Настроить оформление"));
r = await new Visitor(portA).get("/?t=proza-light");
check("разрешённые тема и режим выбираются", r.body.includes("/css/proza-light.css"));
r = await new Visitor(portA).get("/?t=nepomn-time");
check("неразрешённые тема и режим — остаются по умолчанию", r.body.includes("/css/samlib-dark.css"));
r = await new Visitor(portA).get("/theme?url=/");
check("/theme показывает только разрешённое", r.status === 200 && r.body.includes("t=proza") && !r.body.includes("t=nepomn") && !r.body.includes("t=flibusta") && !r.body.includes("-time"));

r = await adminA.post("/panel/look", [["base", "samlib"], ["mode", "dark"], ["b_proza", "1"], ["m_light", "1"]]);
r = await new Visitor(portA).get("/?t=proza-light");
check("настройка скрыта: блока нет, t не действует", r.body.includes("/css/samlib-dark.css") && !r.body.includes("Настроить оформление") && !r.body.includes("ОФОРМЛЕНИЕ"));
r = await new Visitor(portA).get("/theme?url=/");
check("настройка скрыта: /theme — 404", r.status === 404);
r = await adminA.post("/panel/look", [["base", ""], ["mode", "auto"], ["show", "1"], ...["flibusta", "samlib", "proza", "nepomn"].map(x => ["b_" + x, "1"]), ...["auto", "light", "dark", "time"].map(x => ["m_" + x, "1"])]);
r = await new Visitor(portA).get("/?t=nepomn-time");
check("оформление возвращено: всё на выбор, тема из флага -t", r.body.includes("/css/nepomn-time.css") && (await new Visitor(portA).get("/")).body.includes("/css/flibusta-auto.css"));

// ───────────── форматы загрузки ─────────────

const pdf = { name: "scan.pdf", bytes: Buffer.from("%PDF-1.4\n%%EOF\n") };
r = await libA.upload("/b/upload", [["title", "PDF"]], pdf);
check("до настройки: PDF принимается к разбору (отказ по содержимому, 400)", r.status === 400, r.status + " " + msgOf(r.body));

const all = ["fb2", "txt", "epub", "pdf", "djvu"];
r = await adminA.post("/panel/formats", [...all.map(x => ["fs_" + x, "1"]), ["fu_txt", "1"], ["fu_fb2", "1"], ["fu_epub", "1"]]);
check("панель: форматы сохранены", msgOf(r.body) === "Форматы загрузки сохранены.", msgOf(r.body));
r = await libA.get("/b/upload");
check("прочий участник: на странице нет pdf и djvu", r.body.includes("или файл .txt, .fb2, .epub<") && !r.body.includes(".pdf") && !r.body.includes("DjVu"));
r = await libA.upload("/b/upload", [["title", "PDF"]], pdf);
check("прочий участник: PDF — 403, формат не разрешён", r.status === 403 && msgOf(r.body).includes("Формат pdf"), r.status + " " + msgOf(r.body));
r = await libA.upload("/b/upload", [["title", "DjVu"]], { name: "x.djvu", bytes: Buffer.from("AT&TFORM\0\0\0\x10DJVU") });
check("прочий участник: DjVu — 403", r.status === 403 && msgOf(r.body).includes("Формат djvu"), r.status + " " + msgOf(r.body));
r = await libA.upload("/b/upload", [["title", "Текстовая " + Date.now()]], { name: "a.txt", bytes: Buffer.from("Первый абзац.\n\nВторой абзац.\n") });
check("прочий участник: txt принимается", r.status === 303 && /^\/b\/\d+/.test(r.loc), r.status + " " + msgOf(r.body));

// librarian становится сотрудником: остальные права сохраняются как были
r = await adminA.get("/panel");
const rights = [...r.body.matchAll(/name="(r_[a-z0-9_@.:-]+_[a-z]+|blocked_[a-z0-9_@.:-]+)" value="1" checked/g)].map(x => [x[1], "1"]);
const accs = [...r.body.matchAll(/name="acc" value="([^"]+)"/g)].map(x => ["acc", x[1]]);
r = await adminA.post("/panel/rights", [...accs, ...rights, ["r_librarian_staff", "1"]]);
check("панель: librarian — сотрудник", msgOf(r.body) === "Права сохранены." && /name="r_librarian_staff" value="1" checked/.test(r.body), msgOf(r.body));
r = await libA.get("/b/upload");
check("сотрудник: на странице все форматы", r.body.includes("или файл .txt, .fb2, .epub, .pdf, .djvu<"));
r = await libA.upload("/b/upload", [["title", "PDF"]], pdf);
check("сотрудник: PDF снова принимается к разбору (400, не 403)", r.status === 400, r.status + " " + msgOf(r.body));

r = await adminA.post("/panel/formats", [...all.map(x => ["fs_" + x, "1"]), ["fu_fb2", "1"]]);
r = await readerA.get("/b/upload");
const vet = new Visitor(portA);
await vet.signin("vetrov", "vetrov");
r = await vet.post("/b/upload", [["title", "Из формы"], ["text", "Текст из формы."]]);
check("прочий участник без txt: текст из формы — 403", r.status === 403 && msgOf(r.body).includes("Формат txt"), r.status + " " + msgOf(r.body));
r = await adminA.post("/panel/formats", [...all.map(x => ["fs_" + x, "1"]), ...all.map(x => ["fu_" + x, "1"])]);
r = await vet.get("/b/upload");
check("форматы возвращены: всем всё", r.body.includes("или файл .txt, .fb2, .epub, .pdf, .djvu<"));

// B запущен без -pdf и -djvu: панель разрешает всё, но эти форматы не принимает никто
const vetB = new Visitor(portB);
await vetB.signin("vetrov", "vetrov");
r = await vetB.get("/b/upload");
check("без -pdf и -djvu: на странице нет pdf и djvu", r.body.includes("или файл .txt, .fb2, .epub<") && !r.body.includes(".pdf"), (r.body.match(/или файл[^<]*/) || [""])[0]);
r = await vetB.upload("/b/upload", [["title", "PDF"]], pdf);
check("без -pdf: PDF — 403", r.status === 403 && msgOf(r.body).includes("Формат pdf"), r.status + " " + msgOf(r.body));
r = await vetB.upload("/b/upload", [["title", "DjVu"]], { name: "x.djvu", bytes: Buffer.from("AT&TFORM\0\0\0\x10DJVU") });
check("без -djvu: DjVu — 403", r.status === 403 && msgOf(r.body).includes("Формат djvu"), r.status + " " + msgOf(r.body));

console.log(`\n${total - fails}/${total}`);
process.exit(fails ? 1 : 0);
