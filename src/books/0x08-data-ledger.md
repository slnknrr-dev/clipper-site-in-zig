## Members' records: journal and B+ tree

### Fork

Where everything members write is kept: accounts, sessions, rights, comments, forums, boards, drafts, quotes, bookmarks, settings. This is step-three data: it cannot be restored if lost.

### Paths

1. **A relational database** (SQLite and the like).
2. **A file per entity** — a comment as a file, a topic as a folder.
3. **Custom in-memory structures** with a custom save format for each.
4. **One ordered key-value store** for everything.

And within path 4 — how the store itself is built:

- **a journal**: a file that is only appended to, with all state in memory;
- **a copy-on-write B+ tree**: read from disk on demand;
- **an LSM tree**: writes go to memory and a log, with periodic flushes to sorted files and merging of those.

### Choice

One key-value store with five operations: get, put, delete, scan a prefix, flush to disk. A key is a kind letter and a number: `U1001` is a member, `Q17` a quote; a comment's key holds the book number and the comment number, so all comments of one book lie together. A value is fields separated by a control character. The whole "database schema" is one table of letters at the top of `src/db.zig`.

Why one for everything: the site has no queries that need more. Comments on a book — a prefix scan. Forum topics — a prefix scan. A session by cookie — a get by key. There are no table joins, because the catalog lives in the snapshot.

Under the interface there are two stores, chosen at startup.

**The journal** (default). A text file; each line is one operation: plus, key, value and checksum, or minus, key and checksum. Almost everything follows from the single rule "append only": a write torn by a crash is always the last line, and the reader stops before it; corruption in the middle of the file is a line with a wrong checksum, which is skipped and counted; the format is readable by eye and fixable in a text editor. In memory — a sorted array and binary search.

**The B+ tree** (`-btree`). A page reachable from the root is never rewritten: a change copies the path from leaf to root, and which root is current is told by two meta pages written in turn. A crash at any moment leaves the previous tree intact — by construction.

Why two. The journal is simple and fast but keeps everything in memory and reads the whole file at startup. The tree starts instantly and keeps nothing extra, but is several times more complex: seven hundred lines versus two hundred eighty. The right answer depends on the site's size, and there is no need to guess in advance: one interface, the same records, and a test runs one history through both and compares.

### Dead ends

**A file per entity (path 2).** Looks simple, but a file system is a poor database: hundreds of thousands of small files, atomicity only at the level of rename, directory listing without order. A dead end at any noticeable volume.

**Custom structures per entity (path 3).** Ten formats, ten ways to save, ten ways to corrupt on a crash. One store — one way.

**Rewriting the whole file on every change.** Reliable (write to a temporary file and rename), but the cost of a write grows with the data. A dead end after the first thousand records.

### Better — under other conditions

**An LSM tree — with frequent writes.** The journal only grows: a deleted record stays in it forever along with the deletion line. Sessions that are created and expire, board threads that live an hour — everything accumulates. LSM solves this with merging: old versions of keys are dropped on flush. With tens of thousands of writes a day LSM beats both the journal and the B+ tree (in the tree every change copies three or four pages). Clipper never reached that load, and LSM is the most complex of the three structures.

**Journal compaction — the minimal improvement.** Rewrite the journal keeping only the latest values of live keys — a hundred lines. It is not done, and it is a known hole: for a site with active boards the file will one day have to be rewritten by hand.

**Secondary indexes — with moderation.** "All messages awaiting review" in a key-value store is a full scan. Better is to write a second key of the form "state, number" and maintain it on every change. This is exactly the complexity the axis talked about: step 4 brings into storage what step 3 does without.

**SQLite — if the ban on foreign code is lifted.** Honestly: for most sites of this size it is the best choice. It solves compaction, indexes and transactions and has been proven over decades. Clipper does not take it because the frame forbids foreign code and requires running on XP without a C library.

### Price

No "find all where..." queries: any search not by key prefix is a full scan. Values are delimited strings without a schema: appending a field is easy, reordering means writing a conversion of old records. Flushing to disk on every write is the speed ceiling: writes are bound by the disk, and several processes do not speed them up.

Freed tree pages are not reused: the file is compacted only on open. There is no test that cuts a tree write mid-transaction — the journal has such a test; for the tree "survives a crash" remains a promise of the construction.
