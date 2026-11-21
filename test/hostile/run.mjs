// Враждебная сеть (этап 9): сырые сокеты шлют работающему серверу то, чего
// не пришлёт браузер. После каждого случая сервер обязан по-прежнему отвечать.
//
//   zig build fixture -- ПАПКА && clipper -p 3911 -r ПАПКА   (заготовка: стихи, форумы, доски)
//   node test/hostile/run.mjs localhost 3911 [-v] [--slow]
//
// --slow добавляет случаи, которые ждут тайм-аута сервера (≈20 с каждый).

import net from "node:net";

const [host, portS] = process.argv.slice(2);
const port = +portS, slow = process.argv.includes("--slow"), verbose = process.argv.includes("-v");
if (!host || !port) { console.error("usage: node run.mjs HOST PORT [-v] [--slow]"); process.exit(2); }

const sleep = ms => new Promise(r => setTimeout(r, ms));
/** Шлёт куски (с паузой между ними) и собирает ответ до закрытия или тайм-аута. */
function talk(chunks, { wait = 1500, pause = 0, end = false } = {}) {
  return new Promise(resolve => {
    const got = [];
    const s = net.connect(port, host);
    let done = false, closed = false;
    const finish = () => { if (done) return; done = true; s.destroy(); resolve({ text: Buffer.concat(got).toString("latin1"), closed }); };
    s.on("data", d => got.push(d));
    s.on("close", () => { closed = true; finish(); });
    s.on("error", () => {});
    s.on("connect", async () => {
      for (const c of chunks) { if (done) return; s.write(typeof c === "string" ? Buffer.from(c, "latin1") : c); if (pause) await sleep(pause); }
      if (end) s.end();
      setTimeout(finish, wait);
    });
  });
}
// Коды ответов по порядку: ответы режутся по Content-Length (тело одного
// ответа не обязано кончаться переводом строки). `headFirst` — у первого нет тела.
function statuses(text, headFirst = false) {
  const out = [];
  let pos = 0;
  while (true) {
    const m = /^HTTP\/1\.1 (\d{3})/.exec(text.slice(pos, pos + 12));
    const end = text.indexOf("\r\n\r\n", pos);
    if (!m || end < 0) break;
    const len = +(/\r\nContent-Length: (\d+)/i.exec(text.slice(pos, end + 2))?.[1] ?? 0);
    out.push(+m[1]);
    pos = end + 4 + (headFirst && out.length === 1 ? 0 : len);
  }
  return out;
}
const alive = async () => statuses((await talk(["GET /help HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"])).text)[0] === 200;

let fails = 0, total = 0;
async function expect(name, got, want) {
  total++;
  const ok = JSON.stringify(got) === JSON.stringify(want);
  const up = await alive();
  if (!ok || !up) { fails++; console.log(`FAIL ${name}: ответ ${JSON.stringify(got)}, ожидался ${JSON.stringify(want)}${up ? "" : " — СЕРВЕР НЕ ОТВЕЧАЕТ"}`); }
  else if (verbose) console.log("ok   " + name);
  if (!up) { console.log("сервер упал, дальше проверять нечего"); process.exit(1); }
}
const one = async (name, raw, want, opt) => expect(name, statuses((await talk([raw], opt)).text), want);
const H = "Host: x\r\n";
const get = p => "GET " + p + " HTTP/1.1\r\n" + H + "\r\n";

if (!(await alive())) { console.error(`сервер ${host}:${port} не отвечает`); process.exit(2); }

// ── строка запроса и заголовки ──
await one("мусор вместо запроса", "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03\r\n\r\n", [400]);
await one("нулевой байт", "GET /\0 HTTP/1.1\r\n" + H + "\r\n", [400]);
await one("голый LF", "GET / HTTP/1.1\n" + H + "\n", [400]);
await one("нет Host", "GET / HTTP/1.1\r\n\r\n", [400]);
await one("два Host", "GET / HTTP/1.1\r\n" + H + H + "\r\n", [400]);
await one("HTTP/1.0 без Host", "GET /help HTTP/1.0\r\n\r\n", [200]);
await one("HTTP/2.0", "GET / HTTP/2.0\r\n" + H + "\r\n", [505]);
await one("неизвестный метод", "DELETE / HTTP/1.1\r\n" + H + "\r\n", [405]);
await one("адрес без /", "GET http://evil.example/ HTTP/1.1\r\n" + H + "\r\n", [400]);
await one("адрес 3000 байт", "GET /" + "a".repeat(3000) + " HTTP/1.1\r\n" + H + "\r\n", [414]);
await one("заголовок 9 КБ", "GET / HTTP/1.1\r\n" + H + "X: " + "a".repeat(9000) + "\r\n\r\n", [431]);
await one("9 КБ без конца заголовка", "GET / HTTP/1.1\r\n" + H + "X: " + "a".repeat(9000), [431]);
await one("100 заголовков", "GET / HTTP/1.1\r\n" + H + "X: 1\r\n".repeat(100) + "\r\n", [431]);
await one("продолжение строки заголовка", "GET / HTTP/1.1\r\n" + H + " folded: 1\r\n\r\n", [400]);
await one("битый процент в параметрах", "GET /s?q=%zz HTTP/1.1\r\n" + H + "\r\n", [400]);
await one("выход из папки файлов: %2f", get("/files/..%2f..%2fADMIN.env"), [404]);
await one("выход из папки файлов: %2e%2e", get("/files/%2e%2e/clipper.journal"), [404]);
await one("выход из папки файлов: %5c", get("/files/..%5cclipper.journal"), [404]);
await one("выход из папки файлов: диск", get("/files/C:%5cWindows%5cwin.ini"), [404]);

// ── тело ──
await one("POST без длины", "POST /d HTTP/1.1\r\n" + H + "\r\n", [411]);
await one("chunked", "POST /d HTTP/1.1\r\n" + H + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n", [501]);
await one("две длины", "POST /d HTTP/1.1\r\n" + H + "Content-Length: 1\r\nContent-Length: 2\r\n\r\nab", [400]);
await one("отрицательная длина", "POST /d HTTP/1.1\r\n" + H + "Content-Length: -1\r\n\r\n", [400]);
await one("длина 2^64", "POST /d HTTP/1.1\r\n" + H + "Content-Length: 18446744073709551616\r\n\r\n", [400]);
await one("тело у GET", "GET / HTTP/1.1\r\n" + H + "Content-Length: 3\r\n\r\nabc", [400]);
await one("форма больше 64 КБ", "POST /d HTTP/1.1\r\n" + H + "Content-Length: 70000\r\n\r\n" + "a".repeat(70000), [413]);
await one("загрузка гостем 60 МБ (тело не шлётся)", "POST /b/upload HTTP/1.1\r\n" + H + "Content-Length: 60000000\r\n\r\n", [413]);
await one("форма без CSRF", "POST /d HTTP/1.1\r\n" + H + "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 7\r\n\r\ntitle=x", [403]);
await one("multipart без границы", "POST /d HTTP/1.1\r\n" + H + "Content-Type: multipart/form-data\r\nContent-Length: 3\r\n\r\nabc", [400]);
await one("тело оборвано (30 КБ из 60)", "POST /d HTTP/1.1\r\n" + H + "Content-Length: 60000\r\n\r\n" + "a".repeat(30000), [], { end: true });
await one("тело оборвано (1 байт из 5)", "POST /d HTTP/1.1\r\n" + H + "Content-Length: 5\r\n\r\na", [], { end: true });

// ── порядок и темп ──
await one("три запроса одним куском", get("/help") + get("/nope") + get("/b"), [200, 404, 200]);
await one("после плохого запроса остальные не выполняются", get("/help") + "BAD\r\n\r\n" + get("/b"), [200, 400]);
await one("50 запросов одним куском", get("/help").repeat(50), Array(50).fill(200), { wait: 4000 });
{
  const r = await talk([...get("/help")], { pause: 3, wait: 2000 });
  await expect("запрос по одному байту", statuses(r.text), [200]);
}
{
  const r = await talk(["HEAD /b/0 HTTP/1.1\r\n" + H + "\r\n" + get("/nope")]);
  await expect("HEAD без тела, следующий ответ сразу за ним", statuses(r.text, true), [200, 404]);
}
await one("Range за концом", "GET /b/0/txt HTTP/1.1\r\n" + H + "Range: bytes=999999-\r\n\r\n", [416]);
await one("Range -0", "GET /b/0/txt HTTP/1.1\r\n" + H + "Range: bytes=-0\r\n\r\n", [416]);
await one("Range из двух частей отдаётся целиком", "GET /b/0/txt HTTP/1.1\r\n" + H + "Range: bytes=5-2,x\r\n\r\n", [200]);

// ── случайные байты ──
{
  let seed = 2003; const rnd = () => (seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296;
  const alphabet = "GET POST HEAD / ? & = % : ; - . \r\n \r\n\r\n HTTP/1.1 Host: Content-Length: 0 1 9 Cookie: sid= csrf= Range: bytes= \x00 \xff".split(" ");
  const jobs = [];
  for (let i = 0; i < 300; i++) {
    let s = i % 2 ? "GET /" : "";
    const n = 1 + Math.floor(rnd() * 60);
    for (let k = 0; k < n; k++) s += alphabet[Math.floor(rnd() * alphabet.length)] + (rnd() < 0.5 ? " " : "");
    jobs.push(talk([s], { wait: 300, end: i % 3 === 0 }));
    if (jobs.length === 30) await Promise.all(jobs.splice(0));
  }
  await Promise.all(jobs);
  await expect("300 соединений со случайными байтами", "жив", "жив");
}

// ── много соединений ──
{
  // слотов 1024: лишние соединения сервер закрывает, а не копит
  const socks = [];
  for (let i = 0; i < 1500; i++) { const s = net.connect(port, host); s.on("error", () => {}); socks.push(s); if (i % 100 === 99) await sleep(30); }
  await sleep(500);
  for (const s of socks) s.destroy();
  await sleep(500);
  await expect("1500 молчащих соединений разом", "жив", "жив");
  const half = [];
  for (let i = 0; i < 400; i++) half.push(talk(["GET /b/0 HTTP/1.1\r\nHos"], { wait: 50 }));
  await Promise.all(half);
  await expect("400 соединений брошены на середине заголовка", "жив", "жив");
}

if (slow) {
  const t0 = Date.now();
  const r = await talk(["GET / HTTP/1.1\r\nHost"], { wait: 25000 });
  await expect("молчащее соединение закрыто по тайм-ауту", [r.closed, Date.now() - t0 < 20000], [true, true]);
  const r2 = await talk(["POST /d HTTP/1.1\r\n" + H + "Content-Length: 60000\r\n\r\nabc"], { wait: 25000 });
  await expect("недосланное тело закрыто по тайм-ауту", r2.closed, true);
}

console.log(`\n${total - fails}/${total} случаев пройдено` + (fails ? `, провалов: ${fails}` : ""));
process.exit(fails ? 1 : 0);
