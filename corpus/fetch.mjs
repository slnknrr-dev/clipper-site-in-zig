// Корпус для словарей zstd (BACKLOG_RU.md §15): только общественное достояние, источники —
// CORPUS_RU_RND.md. Тексты в git не попадают (.gitignore); этот скрипт их воспроизводит.
//
//   node corpus/fetch.mjs            скачать в corpus/raw/ и очистить в corpus/ru/, corpus/en/
//   node corpus/fetch.mjs --clean    только очистить уже скачанное
//
// Скачивание бережное: Викитека — один запрос в 2 с, Gutenberg — по одному файлу.
// Словарь из корпуса: clipper zstd 16 corpus/ru (BACKLOG_RU.md §16).

import fs from "fs";
import path from "path";

const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const raw = path.join(here, "raw");
const H = { "User-Agent": "clipper-corpus/1.0 (dictionary training; low rate)" };
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ───────────── английский: Project Gutenberg ─────────────

export const gutenberg = [
  [2600, "tolstoy-war-and-peace"],
  [1399, "tolstoy-anna-karenina"],
  [2554, "dostoevsky-crime"],
  [28054, "dostoevsky-karamazov"],
  [1998, "nietzsche-zarathustra"],
  [1004, "dante-divine-comedy"],
  [100, "shakespeare-complete"],
];

async function fetchGutenberg() {
  fs.mkdirSync(path.join(raw, "en"), { recursive: true });
  for (const [n, name] of gutenberg) {
    const file = path.join(raw, "en", name + ".txt");
    if (fs.existsSync(file) && fs.statSync(file).size > 10000) continue;
    for (const host of ["https://www.gutenberg.org", "https://gutenberg.pglaf.org"]) {
      try {
        const r = await fetch(`${host}/cache/epub/${n}/pg${n}.txt`, { headers: H });
        const t = await r.text();
        if (r.ok && t.includes("*** START OF")) {
          fs.writeFileSync(file, t);
          console.log(`en/${name}: ${(t.length / 1024) | 0} КБ (${host})`);
          break;
        }
      } catch {}
    }
    await sleep(2000);
  }
}

/// Без шапки и лицензии Gutenberg: только текст между START и END.
function cleanGutenberg(t) {
  const a = t.indexOf("*** START OF");
  const b = t.indexOf("*** END OF");
  let s = t.slice(a < 0 ? 0 : t.indexOf("\n", a) + 1, b < 0 ? t.length : b);
  return s.replace(/\r\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

// ───────────── русский: Викитека ─────────────

export const wikisource = [
  { file: "tolstoy-voina-i-mir", prefix: "Война и мир (Толстой)", old: false },
  { file: "tolstoy-anna-karenina", prefix: "Анна Каренина (Толстой)", old: false },
  { file: "dostoevsky-prestuplenie", prefix: "Преступление и наказание (Достоевский)", old: false },
  { file: "dostoevsky-karamazovy", prefix: "Братья Карамазовы (Достоевский)", old: false },
  { file: "nietzsche-zaratustra", prefix: "Так говорил Заратустра (Ницше; Антоновский)", old: false },
  { file: "dante-min", prefix: "Божественная комедия (Данте; Мин)", old: true },
  { file: "shakespeare-gamlet-sokolovsky", prefix: "Гамлет, принц датский (Шекспир; Соколовский)", old: true },
  { file: "shakespeare-otello-weinberg", prefix: "Отелло, венецианский мавр (Шекспир; Вейнберг)", old: false },
  { file: "shakespeare-lir-sokolovsky", prefix: "Король Лир (Шекспир; Соколовский)", old: true },
  { file: "tyutchev-stihi", category: "Категория:Поэзия Фёдора Ивановича Тютчева", old: false },
];

const API = "https://ru.wikisource.org/w/api.php";
let last = 0;
async function api(params) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const wait = last + 2000 - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    try {
      const r = await fetch(API + "?" + new URLSearchParams({ format: "json", maxlag: "5", ...params }), { headers: H });
      const t = await r.text();
      if (t.startsWith("{")) {
        const j = JSON.parse(t);
        if (!j.error) return j;
      }
    } catch {}
    await sleep(10000 * (attempt + 1));
  }
  throw new Error("Викитека не отвечает");
}

async function listPages(job) {
  const out = [];
  let cont = {};
  for (;;) {
    const p = job.category
      ? { list: "categorymembers", cmtitle: job.category, cmnamespace: "0", cmlimit: "500" }
      : { list: "allpages", apprefix: job.prefix, apnamespace: "0", aplimit: "500", apfilterredir: "nonredirects" };
    const j = await api({ action: "query", ...p, ...cont });
    out.push(...(j.query.allpages || j.query.categorymembers).map(x => x.title));
    if (!j.continue) break;
    cont = j.continue;
  }
  const isOld = t => /\/ДО$|\/ДО\/|\(ДО\)/.test(t);
  let titles = out.filter(t => (job.old ? isOld(t) || !out.includes(t + "/ДО") : !isOld(t)));
  if (job.prefix) titles = titles.filter(t => t === job.prefix || t.startsWith(job.prefix + "/"));
  return titles;
}

/// Текст готовой страницы: без шапки, навигации, сносок и оформления.
function fromHtml(h) {
  let s = h;
  s = s.replace(/<style[\s\S]*?<\/style>/g, "");
  s = s.replace(/<(table|div)[^>]*class="[^"]*(headertemplate|ws-noexport|noprint|navbox|mw-references)[^"]*"[\s\S]*?<\/\1>/g, "");
  s = s.replace(/<sup[\s\S]*?<\/sup>/g, "").replace(/<span class="pagenum[\s\S]*?<\/span>/g, "");
  s = s.replace(/<(br|\/p|\/div|\/h\d|\/li|\/tr)[^>]*>/g, "\n");
  s = s.replace(/<[^>]+>/g, "");
  s = s.replace(/&nbsp;|&#160;/g, " ").replace(/&mdash;|&#8212;/g, "—").replace(/&laquo;/g, "«").replace(/&raquo;/g, "»")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&#(\d+);/g, (m, n) => String.fromCodePoint(+n)).replace(/&[a-z]+;/g, " ");
  return s.replace(/[ \t]+/g, " ").replace(/\n\s*\n(\s*\n)+/g, "\n\n").trim();
}

async function fetchWikisource() {
  fs.mkdirSync(path.join(raw, "ru"), { recursive: true });
  for (const job of wikisource) {
    const file = path.join(raw, "ru", job.file + ".txt");
    if (fs.existsSync(file) && fs.statSync(file).size > 10000) continue;
    const titles = await listPages(job);
    const parts = [];
    for (const t of titles) {
      const j = await api({ action: "parse", page: t, prop: "text", redirects: "1", formatversion: "2" });
      if (j.parse && j.parse.text) parts.push(fromHtml(j.parse.text));
    }
    fs.writeFileSync(file, parts.join("\n\n"));
    console.log(`ru/${job.file}: страниц ${titles.length}, ${(Buffer.byteLength(parts.join("")) / 1024) | 0} КБ`);
  }
}

/// Дореформенная орфография → новая (буквы и твёрдый знак на конце слова; окончания
/// вроде «-аго» остаются — для словаря это мелочь).
function modern(s) {
  return s.replace(/ѣ/g, "е").replace(/Ѣ/g, "Е").replace(/і/g, "и").replace(/І/g, "И")
    .replace(/ѳ/g, "ф").replace(/Ѳ/g, "Ф").replace(/ѵ/g, "и").replace(/Ѵ/g, "И")
    .replace(/([бвгджзклмнпрстфхцчшщБВГДЖЗКЛМНПРСТФХЦЧШЩ])ъ(?=[^а-яёА-ЯЁ]|$)/g, "$1");
}

function cleanWikisource(t, old) {
  let s = t.split("\n").filter(l => !/^[\s.\d]*$/.test(l) || l === "").join("\n");
  if (old) s = modern(s);
  return s.replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

// ───────────── очистка в corpus/ЯЗЫК/ ─────────────

function cleanAll() {
  for (const lang of ["en", "ru"]) fs.mkdirSync(path.join(here, lang), { recursive: true });
  for (const [, name] of gutenberg) {
    const f = path.join(raw, "en", name + ".txt");
    if (fs.existsSync(f)) fs.writeFileSync(path.join(here, "en", name + ".txt"), cleanGutenberg(fs.readFileSync(f, "utf8")));
  }
  for (const job of wikisource) {
    const f = path.join(raw, "ru", job.file + ".txt");
    if (fs.existsSync(f)) fs.writeFileSync(path.join(here, "ru", job.file + ".txt"), cleanWikisource(fs.readFileSync(f, "utf8"), job.old));
  }
  for (const lang of ["en", "ru"]) {
    let total = 0;
    for (const f of fs.readdirSync(path.join(here, lang))) total += fs.statSync(path.join(here, lang, f)).size;
    console.log(`corpus/${lang}: ${(total / 1024 / 1024).toFixed(1)} МБ`);
  }
}

if (!process.argv.includes("--clean")) {
  await fetchGutenberg();
  await fetchWikisource();
}
cleanAll();
