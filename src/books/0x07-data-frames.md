## Book text: frames, compression, cache

### Fork

Book text takes up most of the catalog. It must be compressed, but a reading page must not decompress the whole book, and a request for part of a file during download must not decompress the whole file.

### Paths

1. Do not compress.
2. Compress the whole book.
3. Compress each chapter.
4. Cut the text into equal pieces (frames) and compress each separately.
5. Cut into frames and compress with a shared dictionary trained on the corpus.

### Choice

Path 4. Text is cut into 16 KB frames, each compressed on its own with deflate. A reading page is limited to 32 KB and is cut at paragraph boundaries, so it spans one or two frames. If a compressed frame is not smaller than the original, it is stored as is — the reader sees equal lengths and knows not to decompress.

Why not chapters: chapters come at 2 KB and at 400 KB. Decompressing 400 KB for one page is wasteful. A fixed-size frame gives a predictable cost for any operation: "no more than two decompressions of 16 KB".

Why 16 KB. Smaller means worse compression: the algorithm has less material to find repeats in. Larger means slower decompression per page. 16 KB is a compromise chosen in the first version; it was not re-measured here.

### Dead ends

**A custom compression model.** The first version tried an order-3 model with an entropy coder: 11% denser than zstd on small frames within its domain, 13% worse outside it and 30 times slower to decompress. For a server that decompresses on every request this is a dead end: the size gain does not pay for the speed loss.

**Punctuation as a separate stream.** Worse by 5.6–9.5%. Dead end.

**Compressing the whole book (path 2).** The best compression, but any page means decompressing the whole book. A dead end for reading online; fit only for an archive.

### Better — under other conditions

**zstd with a dictionary (path 5).** The first version produced a noticeably smaller snapshot: on 383 real books — minus 80% of the source. A dictionary trained on the corpus "knows" the frequent words of Russian, and even a small frame compresses well. This is objectively the best solution. Clipper gave it up for one reason: in the Zig 0.14 standard library zstd can only decompress, and compressing code exists only in C. The "nothing foreign" rule costs disk space here.

That is what was done: zstd was written from scratch (`src/zstd.zig`, about 1200 lines) — decompression of the whole format and compression with hash chains, Huffman-coded literals and custom FSE tables. It is turned on with the `-zstd` startup flag; a build with `-Dzstd=false` does not contain it at all. The dictionary is a separate file `clipperN.zstd`, where N is the frame size in KB (4 to 32). The program trains it itself: `clipper zstd 16` on the library's own texts, `clipper zstd 16 DIR...` on the books in folders. The flag `-zstd 16` takes the file from the current folder or the program's folder, `-zstd PATH` takes the given one, and `-zstd` with no value takes the one the current snapshot was built with, otherwise the largest.

What the measurement on 16 KB frames showed. Without a dictionary our zstd compresses exactly like deflate — 47% of Russian text for both: a small frame has little history for any algorithm. With a 64 KB dictionary trained on only 100 KB of books 1 and 2, book 0 shrinks to 82% of deflate in Russian and 85% in English. Our zstd decompresses at 0.3–0.4 ms per frame, faster than the standard library's deflate. Compression is slower — about 4 ms per frame, but it runs only when the snapshot is built. Then the dictionary was trained on a real corpus: 19 MB of Russian classics from Wikisource and 14.5 MB of English from Gutenberg. The result is sobering. Book 0 — technical text — shrinks to 93% of deflate (94% in English): a dictionary made of Tolstoy and Shakespeare does not know the words "frame" and "snapshot". Literary text that was left out of training gains more: Tyutchev's poems — 93%, Dostoevsky's prose — 89%; in English 91% and 87%. Decompression takes 0.15–0.18 ms per frame, compression 2–3 ms. The more the corpus resembles what the library holds, the more the dictionary helps. That is why the dictionary, first embedded in the program at build time, was moved into a file the site trains on its own texts. The extreme case is a library of book 0 alone: a dictionary made from it compresses its 83 KB to 9 KB against deflate's 45 KB. That is only half fair: the dictionary knows the books already there, and a new book gains less until the dictionary is retrained.

**Price:** a zstd snapshot can be read only with the same dictionary file. So the compression method, the frame size and the dictionary fingerprint are written in the snapshot header and are part of the catalog fingerprint: if they change, the snapshot is rebuilt at startup. Compatibility of the frames with the reference `zstd` program was checked only without a dictionary — with the Zig standard library's decompressor.

### The cache of decompressed frames

Decompressed frames are kept in a cache with a memory budget. A fork within the fork — which eviction algorithm.

- **LRU** (evict the least recently used). The classic. Copes badly with scans: a person pages forward through a book, each frame is read once, and these one-time frames evict what is read constantly.
- **CLOCK** — an approximation of LRU, cheaper in memory, the same trouble with scans.
- **LFU** (evict the least frequently used) — remembers old popularity too long; a book read a month ago holds its place.
- **S3-FIFO** — three queues. A new frame goes to the small one. If it is accessed again, it moves to the main queue; if not, it is evicted and its number is remembered in a "ghost" queue. When such a frame comes back, it goes straight to the main queue.

S3-FIFO was chosen: it is designed precisely for the case where most objects are read once. All of the cache's memory, including room in the hash tables, is allocated at startup; after that the cache never asks for memory.

What is missing: a measurement of how much better S3-FIFO is than LRU under this site's load. In the first version the cache sped up reading pages by 43%, but there the data and compression were different. The choice is justified by a paper (Yang et al., SOSP 2023) and by reasoning, not by measurement. **Better** would be to record real load first and run all four algorithms on it.

### Price

A frame cuts text wherever it falls, including mid-word: a frame is a unit of compression, not of meaning. A cache slot is a whole frame, even if the last frame of a chapter holds a hundred bytes. Small frames compress worse than large ones. All this is the price of predictability.
