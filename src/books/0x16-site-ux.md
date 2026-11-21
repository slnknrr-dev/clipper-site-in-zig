# Part VI. The site

## The site through a visitor's eyes

Before taking the code apart, it is worth walking through the site the way a person does. This part is about what Clipper can do and how it looks from outside. Everything described can be opened right now: the addresses in the text are real.

### The address is the interface

The main thing in Clipper's interface is the address bar. Everything on the site has a short permanent address of a letter and a number, and it tells you what will open.

| address | what opens |
| /p/N | poems, free verse, singer-songwriter songs; /p/-N — a song with chords and notes |
| /b/N | a book; /b/-N — a book series |
| /b/N/K | page K of book N |
| /q/N | start reading book N right away |
| /c/N | a person's quotes; /c/-N — a character's quotes |
| /d/N | a draft; /d/-N — an article |
| /f/N | a forum; /f/name — an anonymous board |
| /v/N | a recording: audiobook or performance; /v/-N — a reader or performer |
| /u/N | a member; /u/-N — an author; /u/0 — the administrator |
| /s | search |
| /e | embedding on other sites |

The sign of the number tells related things apart. A book and a book series are both about books, so both live under the letter b. A person and the character they invented both speak in quotes, so both are under c. That keeps the scheme short: eleven letters for the whole site.

Number zero is special. `/b/0` is this book. `/u/0` is the built-in administrator through whom the site is set up. Other zero addresses do not open.

The `/help` page shows the whole scheme as one table, and that is no accident: a site whose structure fits in a table needs no guidebook.

### What a guest sees

The home page is a summary of the enabled sections: the latest books, the latest poems, fresh drafts, forums and the quote of the day. Which sections a site has is decided by whoever runs it (see "Sections" below), and the home page is built only from them. A guest can read everything open to them, search, download books and post on anonymous boards. Commenting, keeping drafts and marking quotes need an account.

There is one search, on the `/s` page: it searches titles, annotations, poems and, while the library is small, the full text of books. The answer is one table: what was found, what it is called, whose it is.

## Reading, quotes and bookmarks

### The reading page

A book is read page by page: `/b/N/1`, `/b/N/2` and so on. A reading page is a chapter, or part of one if the chapter is long. Above and below are page controls, at the side a table of contents showing where you are. A page's address is permanent: it can be saved, sent on, put in browser bookmarks.

Every paragraph has an anchor: `/b/0/1#p3` is the third paragraph of the first page of this book. It can be linked to.

### A quote starts in the book

In Clipper you cannot type a quote by hand. You can only select it in a book. This interface decision has a reason: a quote without a source is a claim that someone said something. A quote made from the text is its own proof: it keeps the book, the page, the paragraph, and leads back to where it was taken from.

How it is done. On the reading page, select a fragment within one paragraph and press the right mouse button. Instead of the browser's menu, the site's menu appears with two items: "Bookmark with a note" and "Quote". The browser's usual menu remains available with Shift and the right button. If scripts are off or there is no mouse, below the text there is a "Mark a fragment" form, and on a phone a "Mark the selection" button.

- **A bookmark** is private. Only you see it, on the `/bookmarks` page, together with your note. It is a way to come back.
- **A quote** is public. It appears in the quotes section and is highlighted in the book's text for everyone.

A quote is made from a poem, a song or an article the same way: select in the text and choose "Quote" (bookmarks are only for books). It is attributed to the poem's or article's author and leads back to its paragraph or verse.

### Whose words are these

A quote is attributed either to the book's author or to a character. The words about "the nastiest little town of all the seaside towns of Russia" were written by Lermontov but spoken by Pechorin. Clipper distinguishes these two cases, a care rare among libraries.

A character is created in advance, on the quotes page. It belongs to an author and can be tied to one book, to several or to none: then it counts as a character of everything the author wrote. Onegin is Pushkin's character even if the novel itself is not in the library. Character numbers are negative: `/c/-2`.

A quotes page can be narrowed right in the address: `?op=` — the start of the quote, `?ed=` — the end, `?sz=` — no longer than so many sentences.

## Your own texts: drafts, poems, books

### A draft

A member with the right to write keeps drafts at `/d`. A draft is working text: it can be edited as much as you like. It has tags and a date.

From there a draft has two paths, both one-way.

- A draft can be moved to poems: it gets the address `/p/N` and no longer changes.
- Several drafts can be assembled into a book: each becomes a chapter, the book gets the address `/b/N`, and its page says which drafts it was assembled from.

After the move the original draft remains, but read-only. That too is a decision, not a limitation: what has been published is not rewritten after the fact. Someone may already have linked to it or taken a quote from it.

An article is a draft with a negative number, `/d/-N`. It is a text about the site, about books, about anything: a member's blog.

A draft or an article can be deleted by its author, staff and `/u/0`. If the draft has already become a poem or a book chapter, what was published stays and only the trace goes: the "assembled from drafts" note. As if it had been posted in that name straight away.

### Poems and songs in an author's name

A poem by Tyutchev is not posted through a draft: the page `/p/new` takes a poem or a song in the name of any author. The author is picked from the site's people or typed in by name, and a new person — with years of life — is created by itself, as when uploading a book. Who posted it is kept separately and shown on the page: "Posted by: …". Any member with the "drafts" right can post.

A song with chords is written in ChordPro — chords in square brackets right inside the words: `[Am]Night, the pet[Dm]rol and the wind`. The chorus goes between the lines `{soc}` and `{eoc}`, a remark — `{c: text}`; the melody can be added in ABC notation. On the page each line with chords is a small two-row table: the chord stands over its syllable in any font, without CSS3 or JavaScript, like everything on the site.

A poem can be edited and deleted by whoever posted it, a staff member and `/u/0`.

An author has their own page on the site, `/c/N`: their poems and songs, books, characters, photo and pinned discussions — forums and boards. The author's profile (name, years, description, photo, discussions) is edited by staff, `/u/0` and the members linked to the author. Members have a photo and discussions too, and edit their own profile at `/u/N/edit`. The photo goes through the same processing as book pictures and stands on the page in a 240x320 place, centred. Also by the member who is the author: a staff member or `/u/0` links them on the member's page to one or several of the site's people ("this member is Tyutchev"), and then they manage everything posted in those names, books included.

### Uploading a book

The `/b/upload` page accepts a book as text from a form or as a file. There are five formats.

| format | what is taken from it |
| txt | text; chapters are lines starting with two hashes |
| fb2 | description, text, pictures and cover |
| epub | description, reading order, text, pictures and cover; protected files do not open |
| pdf | text layer only; experimental — only when started with -pdf |
| djvu | text layer only; experimental — only when started with -djvu |

PDF and DjVu are experimental formats. The library neither stores nor serves them: the text is taken from the file, and from then on the book lives as text. Parsing these formats is the heaviest and riskiest part of uploading, so it is turned on explicitly: with the -pdf and -djvu startup flags. Without the flag nobody can upload the format, whatever the panel allows; the panel marks such a format "off". A build with -Dpdf=false or -Ddjvu=false has no parser at all, and the flag becomes an unknown argument.

Whatever is sent, the book is brought to one form: title, author, series, year, annotation and chapters of paragraphs. Downloads are later built from this form.

### Pictures in books

Pictures are taken only from FB2 and EPUB; not from PDF and DjVu. PNG, JPEG, GIF (the first frame of an animation), WebP (lossy and lossless, with alpha, the first frame of an animation) and SVG are understood. A raster picture is shrunk, keeping its proportions, to fit an 800x600 place; a small one is not stretched. Without transparency it is saved as JPEG at quality 80 — smaller that way; with transparency, as PNG. SVG is drawn by our own rasterizer straight at its own size fitted into the place and kept as PNG: shapes, paths, strokes, dashes, gradients and simple styles are taken; text, filters and masks are not. Reading all formats, rasterizing, shrinking and writing are written in the program from scratch, like zstd; the readers were checked against the Windows decoders (GIF, WebP — bit-exact), SVG against a browser's rendering.

On the reading page a picture stands as its own paragraph in an 800x600 place; in a narrow column the place shrinks without changing its proportions. The picture fits into it whole and is centred on both axes — wide, tall or square. The server computes the position in percent of the place, so the layout holds in old browsers too, without CSS3. Under the picture is its caption from the book. The cover is shown on the book page, not in the catalogue.

Finished pictures live in the img/b/ folder (the pictures folder can be set with -img) under a name made from the source's fingerprint. The catalog snapshot keeps only links to them, so rebuilding it does not touch the pictures: a picture is processed once, at the first build where its book appears, and the same picture in different books is one file. Pictures that neither the current nor the previous snapshot refers to are removed. Downloads in txt, fb2 and epub carry no pictures.

Refusals are explained in words. A scan without a text layer — "these are pictures of pages; the site does no OCR". A password-protected PDF — said so. A PDF with an embedded font lacking a character map — said so. A site that accepted a file and showed garbage instead of a book is worse than one that refused and explained why.

The command `clipper convert FILE` prints what would come out of a file without starting the server: that is how a book is checked before uploading.

### Recordings: audiobooks, readers and performers

The `/v` section is what sounds. Recordings come in two kinds: an audiobook goes with a library book, a performance with a poem or song in `/p`; a performance may have its own words and notes if it is sung differently from what is written. The text is optional: a recording can be uploaded without a book or poem and linked later, in either order — from the recording's page (link it to an uploaded one, or upload the book or text right from it) or from the book's or poem's page (upload a recording, or link one uploaded without a text). Every recording has a reader or performer, `/v/-N`. They do not have to be a site member; staff or `/u/0` may bind a member to them, as to an author, and the member edits the reader's recordings. The reader may be the author: the reader is linked to the author, their recordings are marked "(author)", and the author's page shows that they read their own work.

A book, poem or recording may name its source — an address or a name: mrakopedia, arxiv, habr. An address is shown as a link with the site's name.

| address | what opens |
| /v | all recordings and readers |
| /v/N | a recording: player, download link, words and notes as performed |
| /v/N.mp3 | the file itself; also served in pieces (Range) for seeking |
| /v/-N | a reader or performer and their recordings |

MP3 is always accepted, Ogg Vorbis if built with -Dogg (yes by default), M4A with AAC with -Dm4a (no by default). Whatever arrives is re-encoded into MP3 "as before 2003": MPEG-1 Layer III, constant 128 kbit/s, 32, 44.1 or 48 kHz, an ID3v1 tag in windows-1251 and no VBR, Xing or ID3v2 with pictures. Any player of that time will play such a file, and on the page a modern browser plays it through `<audio>` as well. MP3, Vorbis and AAC decoding and the MP3 encoder are written in the program from scratch; Huffman tables and windows are checked against ffmpeg, and the output against the browser's decoder: identical down to rounding noise. A build with -Dvoice=false has no such section at all.

### Downloading a book

Any book can be downloaded as txt, fb2 and epub. The files are not stored: they are built on request from the same canonical text the reading page shows. So they always match what is on the site and take no space. Downloads support resuming.

## Conversations: comments, forums, boards

The site has three kinds of conversation, and they differ in how long what is said lives.

### Comments on a book

Below a book there are comments. You can reply to a comment but not to a reply: the depth is two levels. A reply to a reply goes into the same thread. This limit is deliberate: a tree ten levels deep on a narrow screen turns into a staircase of three words per line, and an argument between two people takes the whole screen.

A comment has a permanent address: `/b/N/-1` is the first comment, `/b/N/-1-2` the second as a reply to the first. The server checks the pairing: the address `/b/N/-1-1` does not open, because a comment cannot be a reply to itself. A link that opened always describes what exists.

### Forums

`/f/1`, `/f/2` are ordinary forums: sections, topics, messages in order. Everything stays forever. This is the place for long conversations people come back to.

### Anonymous boards

`/f/b`, `/f/lit` are boards: anyone can write, without a name, with a picture. Each board has a thread lifetime — an hour, six hours, a day. When it runs out, the thread disappears entirely and without a trace.

This is the opposite of a forum, and it is needed for what a forum is no good for: saying something non-binding. A conversation that will not remain is held differently from a conversation for the archive. A library where you can only speak in fair copy comes out stiff.

## Members, rights, panel

### Sign-in and sessions

Sign-up is `/signup`, sign-in `/signin`. The `/logout` page is not just a button: it lists your sessions with the addresses they were opened from and lets you close any one or all at once. If you signed in on someone else's computer and forgot to sign out, it can be fixed from any other.

Passwords are stored as Argon2id hashes. A session is a random value in a cookie; the server keeps only its hash, so the store's contents cannot be used to sign in. All forms are protected against request forgery.

### Six rights

A member has six rights, each switched on separately.

- **forum** — post on forums;
- **comments** — comment on books;
- **drafts** — keep drafts and articles;
- **quotes** — make quotes;
- **upload** — upload books;
- **staff** — everything `/u/0` can do: the site panel, editing and deleting other people's work, linking members to authors, authors' profiles.

A new member gets the first four. The rest are granted by staff or `/u/0`.

`/u/0` has one privilege over staff — staff rights. Only `/u/0` grants and removes the staff right; nobody can take `/u/0`'s rights away, not even `/u/0`. Staff change other members' rights, but not their own and not other staff's: those rows of the rights table are read-only for them.

### The built-in administrator

`/u/0` is one built-in account. Its sign-in is set by startup flags: `-l` — the login (admin by default), `-pwd` — a plain-text password or `-phc` — an Argon2id hash string; `-pwd` and `-phc` cannot be given together. Without a password `/u/0` cannot be signed into. Sign-in works only from the machine where the server runs.

This is not a way to run the site day to day but a way to set it up: sign in locally, give someone the staff right — and from then on staff run the site, from anywhere. Built-in books, this one included, are credited to `/u/0`.

The `/panel` page is the site's control desk for staff and `/u/0`.

- **Twelve switches.** Poems, books, quotes, drafts, forums, boards, uploads, comments, downloads, embedding, badges, sign-up. What is switched off disappears from the menu and answers 404. The switches can only narrow what the startup flags allowed: a section turned off by a flag is not shown in the panel at all, and a "read-only" section cannot be opened for writing from the panel.
- **Members' rights** — a table: who can do what, who is blocked.
- **Appearance** — the default theme and mode, which themes a visitor may choose, and whether the visitor sees this setting at all.
- **Upload formats** — separately for staff and for everyone else.
- **Federation** — the list of neighbouring sites.
- **Forums and boards** — create a new forum (title, description) or board (address `/f/name`, title, thread lifetime). There is no other way to create them.

For other members `/panel` is their own settings.

## Sections: which site to build

Clipper has five sections, each with its own letter: `p` — poems and songs, `b` — books (with bookmarks and uploads), `d` — drafts and articles, `f` — forums and anonymous boards, `q` — quotes, people and characters. Members, search, embedding and badges are always there, but show only what is open to the visitor.

Four startup flags decide what can be done with each section. The flag is followed by the section letters run together.

| flag | meaning | guest | member | moderator |
| (none) | everything open | reads | reads and writes | reads and writes |
| -M | only moderators write | reads | reads | reads and writes |
| -R | read-only for everyone | reads | reads | reads |
| -G | open to guests, the rest after sign-in | reads | — | — |
| -N | the section does not exist | 404 | 404 | 404 |

A moderator is a member with the "staff" right, and `/u/0` itself. `-R` is stronger than `-M`. `-G` is a list, not an addition: if it is given, a guest sees only the listed sections, and the rest disappear for them from the menu, the home page and search; a direct address of a closed section leads to the sign-in page. Errors in the combination — a letter from `-N` in another flag, a repeated letter, an unknown letter — stop the startup with one clear line.

The five letters give different sites, and each of the four themes has its own home page for them — in the full and the mobile version:

| site | flags | home page |
| full library | — | everything at once |
| songbook | -Nbdfq | poems by first line, songs with chords separately |
| reading room | -Ndfpq -Mb | new arrivals, series, authors |
| reading room with quotes | -Ndfp | new arrivals and a large quote of the day |
| forum | -Nbdpq | a table of forums, boards below |
| quote book | -Nbdfp | quote of the day, people and characters, fresh quotes |
| workshop | -Nbq | fresh drafts and articles, discussions |

The theme's layout does not change — the menu and the home page do. Header texts are also assembled from the enabled sections: a songbook does not call itself a library, and a forum does not invite you to search for books. The quote book is a special case: books are hidden in it, but a quote leads "to the place in the book", and the book opens read-only.

Why flags and not just the panel: a flag is the decision of whoever runs the site, and it does not depend on data. The panel keeps its choice in the record store and can be changed on a running site; a flag sets a ceiling the panel cannot raise. A site started as a forum will not become a library because someone clicked a switch.

## Appearance: four themes, three modes

### Themes

The site has four looks: `flibusta`, `samlib`, `proza`, `nepomn`. Each reproduces the layout of a real early-2000s site: where the menu is, where the search is, what a list looks like. These are not four color sets but four different page layouts.

A theme is chosen with the address parameter `t`, and it is kept across navigation: having opened `/b/2?t=samlib`, you stay in that theme wherever you go. A link with a theme can be sent on, and the recipient sees what you see. The setting does not live in a cookie, so it works without cookies too.

### Modes

A mode is added to the theme: `-light`, `-dark`, `-time`. Without a suffix the theme follows the device setting. `samlib-dark` is always dark. `samlib-time` is light by day and dark by night, by the server's clock.

Colors are separate from markup. A page does not know its mode: it links to the stylesheet `/css/samlib-dark.css`, which holds variables with colors. So one theme's markup is the same for all modes and is cached once.

### Mobile version

The parameter `m=true` turns on the mobile layout: one column, large text, menu columns move down. Without the parameter the server decides by the browser's header. Like the theme, the parameter is carried through links.

### The settings page

All of this is gathered on the `/theme` page. It remembers where you came from and returns you there in the new look.

## Embedding, badges and neighbours

### Embedding

Almost anything on the site can be shown on another site through an iframe: a book card `/e/b/N`, a chapter, a poem, a person's quotes, an author page, a forum, site counters, a banner. The `/e` page shows all of it live, next to the code to copy. Every book page has a ready line for embedding.

### Badges

Addresses like `/x/b/reads.svg?id=0` return a small picture with a counter: how many times a book was read, how many comments it has, how many books an author has. Without an extension you get JSON, with `.png` a raster image for places where SVG is not shown. The label and color are set by parameters.

Embedding and badges are how the site is present beyond its own borders: in an author's blog, in a forum signature, on friends' pages.

### Federation

Several Clipper sites can trust each other. A member of one site enters another under their own name — without registration and without a password. On the `/fed` page they click "go", and find themselves on the neighbouring site as a guest named like "name@site".

Inside, it is built so that the password never leaves its own site. The first site issues a one-time ticket that lives two minutes and sends the browser to the neighbour. The neighbour itself asks the first site whether the ticket is genuine and gets back the member's number and name. After that the ticket is burnt.

A guest from a neighbouring site is a member with restrictions: they have no password, their session expires after 45 minutes of inactivity, and it does not federate further. Which neighbours may come in here and where one may go from here is decided by the administrator — with a table in the panel or with the file `FEDIVERSE.csv`, which can be edited while the server runs.

### For whoever runs the site

The whole launch is one command: `clipper -p PORT`. The port is required; everything else has defaults.

| flag | what it does |
| -r FOLDER | library folder; the current one by default |
| -t THEME | the look for those who have not chosen their own |
| -d MODE | light (false), dark (true), by device (auto) or by clock (time) |
| -c COLOR, -b COLOR | core and brand colors: the shades of all themes are recomputed from them |
| -ico FILE, -png FILE | your own icon and logo instead of the built-in ones |
| -M, -R, -G, -N SECTIONS | what can be done with sections (see "Sections") |
| -s ADDRESS, -n NAME | the site's address and name in the headers |
| -btree | keep records in a B+ tree rather than the journal |
| -img DIR | pictures folder (books' in DIR/b, boards' in the folder itself); ROOTDIR/img by default |
| -zstd [N or FILE] | compress catalog frames with our zstd and the dictionary file clipperN.zstd |
| -pdf, -djvu | allow uploading PDF and DjVu (experimental) |
| -w N | how many processes serve the site |
| --tls-cert, --tls-key | answer over https |
| -fed | turn on federation |
| -l, -pwd, -phc | sign-in of the built-in administrator /u/0 |

The interface language is chosen at build time: `zig build -Dlang=en` gives an English site with the built-in books in English. The translation is the catalog `src/t9n/en.t9n`: a source string and its translation; a running server does no translating at all, the strings are substituted at compile time.

On first start the server creates folders and builds the catalog. A fresh site is empty: it holds only the built-in books (`-Dbook0`, `-Dbooks`) and the administrator `/u/0`. There are no poems, members, characters or forums in the program. Forums and boards are created by `/u/0` in the panel; the rest is written by members and brought in by the `books/` folder. If a flag is wrong, a certificate does not fit or a settings file is corrupted, the server does not start and prints one clear line. A server that started with half its settings is more dangerous than one that refused to start.

In the library folder everything lies in the open: `books/` — source books, `library.N.snap` — the catalog snapshot, `clipper.journal` — members' records, `files/` — files the site serves. A backup of the site is a copy of this folder. So is a move to another machine.
