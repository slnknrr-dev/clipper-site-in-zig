## What is not done and not verified

The research ends with a map of the places where what was said stops being proven.

### Not verified

- **Linux in operation.** The Linux build passes (`zig build -Dtarget=x86_64-linux`) but is not among the target builds; the network probe, measurements and process races ran only on Windows 11.
- **Real Windows XP.** The XP builds (32 and 64 bit) are marked for Windows 5.1, the import table was checked, and both were run on Windows 11. The server was never run on XP itself.
- **Home page screenshots per section combination.** The crawl test checks links and texts of every combination in every theme, but the look can be compared with the themes' originals only by eye.
- **A crash mid-write in the B+ tree** — resilient by construction, no test.
- **A full in-memory TLS handshake** — keys are checked against references and it works with curl and openssl; no third-party audit.
- **Other people's book files.** PDF — from two browsers, EPUB — our own export, DjVu — two books without a table of contents.
- **Federation over https** between two sites.
- **The frame cache versus a simpler one** — chosen from a paper, not a measurement.
- **Load from the network** — the measuring client ran on the same machine.

### Not done

- Journal compaction: the file only grows.
- Reclaiming space in the B+ tree without a restart.
- Book parsing and the neighbour question outside the event loop.
- A "hidden" flag for messages (minimal moderation, page 0x12).
- A warning to the visitor that full-text search is off because of the library's size.
- Separate types for raw and escaped strings.
- zstd by default: the snapshot is still compressed with deflate; zstd with a dictionary file only with the `-zstd` flag; the dictionary is not retrained by itself as the library grows.

### How to reproduce

```
git clone https://github.com/slnknrr-dev/clipper-site-in-zig
cd clipper-site-in-zig
zig build -Dlang=en
zig-out/bin/clipper -p 3000 -pwd PASSWORD
```

The site opens at `http://localhost:3000/`, this book at `/b/0`. You can sign into `/u/0` from the same machine with the login admin and the password from the flag.

| command | what you get |
| zig build | target builds in .build (nt-i686-en-all, nt-x86_64-en-nobook, nt51-i686-ru-all, nt51-x86_64-ru-all, linux-x86_64-en-all) and a server for this machine in zig-out/bin |
| zig build -Dlang=en | interface and books in English |
| clipper -p 3000 -Nbdfq | a songbook: poems and songs only |
| zig build -Dbook0=false | without this book: /b/0 answers 404 |
| zig build -Dbooks=true | with books /b/1 (on Zig) and /b/2 (on the web) |
| clipper zstd 16 | the dictionary clipper16.zstd from the library's own texts |
| clipper -p 3000 -zstd | catalog frames compressed with our zstd and the dictionary file |
| zig build -Dzstd=false | without zstd: neither the -zstd flag nor the clipper zstd command |
| clipper -p 3000 -pdf -djvu | uploading PDF and DjVu (experimental) |
| zig build -Dpdf=false -Ddjvu=false | without PDF and DjVu parsing |
| zig build test | unit tests and hostile input |

## Instead of an afterword

If only one paragraph of the whole book were kept, it would be this. Split the data into what is read and what is written. Prepare the first in advance and leave it alone. Write the second in the simplest way that survives a crash. Do not do on a request what can be done before it. And ask every feature of the site which step it lifts the server to — before adding it.

The library this project is dedicated to stayed afloat not thanks to technology. It stayed afloat thanks to people and a few simple decisions made in time: a short address, open data, many doors. Clipper is an attempt to take those decisions seriously and see how far one can go with a single executable.

The ship in the logo is fast. But the main thing about a ship is that it stays afloat.

Yury Slinkin, 2026
