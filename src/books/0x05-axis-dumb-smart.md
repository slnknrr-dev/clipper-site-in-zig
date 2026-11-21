# Part II. The main axis

## The less the site does, the dumber the server

This is the main idea of the book, and it will come back on every page. A server's complexity is not a property of the language, not a property of the library's size and not a matter of skill. It is set by the list of things a visitor can do on the site. Every feature brings work into the request path and data of a certain kind into storage. Remove a feature — and the server can be made dumber and faster. Add one — and it becomes smarter and slower.

Below is a ladder. Each step says what the site can do, what the server must do on a request, and what it costs.

### Step 0. Immutable static content

The site can: show pages.

The server does: finds a file by address and sends the bytes. That is all.

This is the fastest server possible. Pages can be built once, compressed, put in memory or on disk and served without a single decision. Such a server is bound by the network, not the processor. It needs no disk writes, no locking, and it cannot corrupt data.

Clipper at this step is `/b/N/K` for a guest: a reading page taken from the cache of finished pages. 70,600 pages per second from one thread, 0.86 ms on average. If the whole site were like this, the cache could be replaced by prebuilt files and the server by twenty lines.

### Step 1. A catalog that rarely changes

The site can: show books, search, download in various formats.

The server does: finds the record in the catalog, assembles a page from ready pieces, sometimes decompresses text.

Two things are new here. First, there are more pages than can be built in advance: book, format, theme and mobile version in every combination. So assembly on request is needed, if simple. Second, the catalog sometimes changes, and the server must notice the new version.

Clipper's answer is an immutable snapshot (page 0x06). The server does not know the catalog can change: it only sees "there was a file, now there is a new file". This keeps almost all of step 0's dumbness.

### Step 2. Members

The site can: sign-in, sessions, rights, personal pages.

The server does: on every request reads the cookie, finds the session, checks rights, builds a page with the visitor's name.

This is the first real jump. A page no longer depends only on the address: a signed-in visitor gets their own. The cache of finished pages stops working for everyone — in Clipper it works only for guests. Writes appear: a session must be created, and it must survive a restart. Secrets appear: passwords, tokens, protection of forms against forgery.

The price in numbers: a page for a signed-in visitor is built every time, and that is no longer 0.86 ms but several milliseconds. 15,400 pages per second past the cache versus 70,600 from the cache — four and a half times.

### Step 3. Writes by members

The site can: comments, forums, drafts, quotes, bookmarks, uploading books.

The server does: accepts data from strangers, validates it, records it so that it is not lost, and makes it visible to others.

This is the step at which a server stops being a "distributor" and becomes a "system". New duties:

- **durable writes** — a write is confirmed only once it is on disk; that is `fsync`, and it is slow;
- **ordering** — two comments must not get the same number; with several processes that means locking;
- **cache invalidation** — a guest page with comments goes stale the moment a write happens;
- **hostile input** — every form field and every uploaded file may be an attack;
- **data growth** — what is written accumulates; you have to think about where it will be in a year.

Here you can also see why shrinking the catalog barely simplified Clipper compared to the first version. The complexity of step three does not depend on the number of books. A forum with a hundred messages needs the same durable writes as a forum with a hundred million.

### Step 4. Moderation

The site can: premoderation, reports, hiding, bans, different rights in different sections.

Clipper is not on this step. It has only member blocking, member rights and section rules set by startup flags ("only moderators write", "read-only"). But it is worth describing what would happen if it climbed: it shows well how a server's "mind" grows.

- **A message's state** stops being "exists or not". "Awaiting review", "hidden", "hidden from all but the author", "shown to moderator" appear. Every page view passes through the decision "what of this does this person see".
- **A page stops being the same for all guests.** If the author sees their hidden message and others do not, the cache of finished pages breaks for signed-in visitors and, through the author, for guests of the same page.
- **An action history is needed.** Who hid it, when, why — otherwise moderation becomes arbitrariness that cannot be untangled.
- **Queues are needed.** The "awaiting review" list is a query "find all with such-and-such state". In a key-value store without secondary indexes that is a full scan.

Each of these items adds decisions to the request path. The server becomes smarter — and slower, and more complex, and it gains more ways to err in the direction where something that should be hidden is visible.

### Step 5. Feeds, votes, recommendations

The site can: "new from those you follow", ratings, "you might like".

This is a different class of server. Every signed-in visitor's page is unique. Votes must be aggregated, and that cannot be done on request. Background jobs, recalculations, second-level caches appear, along with the eternal question "how stale can we show it". This is exactly the point where one program stops coping and a queue and separate workers appear.

### What follows for Clipper

Clipper stands on step three and deliberately does not climb to step four. That is not laziness but a decision: for a community of a few thousand people, moderation is a person with rights and a "block" button. Introducing a message state machine for two cases a month would make the whole server smarter for the sake of a rare event.

And the reverse: if Clipper dropped forums, boards, comments and drafts and kept only the catalog and reading, the server could be made noticeably dumber. The section flags (`-Ndfpq -Rb`) already assemble such a site from the same program — but the writing code stays in it, just never called. The real gain would come from a different program:

- No write journal — the catalog is only read.
- No sessions or passwords — nobody signs in.
- No change-tracking cache — pages can be built in advance and served as files.
- No multiple processes with locking — any number of processes can read without any coordination.
- No parsing of forms and uploads — the main source of hostile input disappears.

By a rough estimate, that would remove about half of the server's code: `ledger.zig`, `journal.zig`, `btree.zig`, `auth.zig`, most of `pages/` and everything related to book uploads. Speed for a guest would barely change — it is already bound by step 0. What would change is the speed for everyone else and, above all, the number of places where you can make a mistake.

### The axis works both ways

It helps to keep this axis in mind for any decision about site features. "Should we add a series subscription?" is not an interface question. It is "are we ready for every signed-in visitor to have their own home page", and therefore "are we ready for the cache to never work for signed-in visitors". "Do we need premoderation?" is "are we ready for a state machine in every view".

Good architecture is not the one that can do everything. Good architecture is the one where you can see what each feature costs, and where you can decline to add a feature knowing the price of declining.
