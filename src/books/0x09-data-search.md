## Search

### Fork

A visitor types a word. The site must find the books, poems and quotes that contain it — in titles, annotations and, if possible, in the text.

### Paths

1. **Sequential scan**: walk all records and check for a match.
2. **A trigram index**: for each triple of letters, a list of documents where it occurs; a query intersects the lists.
3. **An inverted word index** with normalization (stemming, stop words) and ranking.
4. **An external search engine.**

### Choice

Path 1, with a limit. Titles, annotations and poems are always scanned. The full text of books is scanned only while the snapshot has no more than 2048 frames (about 32 MB of text); beyond that full-text search switches itself off. Matching is case-insensitive, byte by byte in windows-1251, where lowercasing is a 256-entry table (page 0x13).

Why: for one community's library, scanning 32 MB in memory takes milliseconds to tens of milliseconds and needs not a single structure. Search is a rare request compared to reading. The server stays dumb.

### Dead ends

**Unlimited full-text search.** In a large library a single query "a" decompresses the whole catalog. That is not only slow, it is a way to stop the server with one address. A limit is mandatory for any path 1.

### Better — under other conditions

**Trigrams (path 2) — for a large catalog.** The first version did exactly this: a trigram in windows-1251 is three bytes, that is, a number below 16,777,216, and indexing by it is arithmetic. Search finds substrings, not just words, and does not need to know the language. The price is an index in the snapshot the size of a noticeable share of the text, and a more complex build.

**An inverted index (path 3) — when precision matters.** "Book" and "books" are one word to a person and different ones to substring search. Normalization solves this but needs a language dictionary and turns search into a separate product. For a library where people mostly search by title and author, it is overkill.

**Facets — for a catalog with metadata.** The first version could do "genre, year and language at once". That turns search into a query over several indexes at once — one more step of server intelligence.

### Price

Full-text search disappears as the library grows — silently, without telling the visitor. That ought to be shown. There is no ranking: results come in order of number.
