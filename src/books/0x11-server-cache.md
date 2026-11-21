## The page: assembly, templates and the finished-page cache

### Fork

How a page is assembled, and which of that work can be skipped on each request.

### Paths

1. **A template engine at request time**: parse the template, evaluate expressions, concatenate.
2. **A template parsed at startup**.
3. **A template parsed at compile time**: the program already holds the ready sequence "piece — insertion — piece".
4. **Finished pages on disk** (static generation).

### Choice

Path 3 for all pages, plus a cache of finished pages for guests.

Theme templates are compiled into the program and cut at `{{name}}` markers at compile time; they are also re-encoded to windows-1251 there. An unknown name in a template is a build error. What is left for the request is "write a piece, call a method, write a piece". How this is done with the language's means — book 1, the chapter on compile-time evaluation.

A finished response is two pieces of memory: header and body. The body may lie in the page buffer, in the cache or directly in the mapped snapshot, and both pieces go out in one system call without copying.

**The guest page cache.** A guest is a request without a session cookie. Their page depends only on the address, the theme and mobile mode. The cache key is the path plus `t` plus `m`; invalidation is by the snapshot generation number and the store's change counter. Any member write invalidates the whole cache. Section rules (the `-M`, `-R`, `-G`, `-N` flags) do not get in the cache's way: they are set at startup and are the same for all guests, so a guest page still depends only on the address.

**Colors separate from markup.** Light, dark and "by time of day" are CSS variables in a separate file `/css/theme-mode.css` with long browser caching. One theme's markup is the same for all modes and is cached once.

### Dead ends

**A cache for signed-in visitors.** Every signed-in page has their name, their form-protection token, their rights. Only pieces without these can be cached, and then the cache turns into assembly from cached pieces — which the server does anyway. A dead end at step three of the axis.

**Targeted invalidation.** Knowing which pages a new write affected means storing dependencies "which page depends on which data". That is more complex than the cache itself. Dropping everything on any write is cruder but always correct. For a site with few writes, crude beats precise.

### Better — under other conditions

**Static generation (path 4) — if writes are given up.** At step two of the axis the whole site can be built into files on every snapshot rebuild and served by any server. That is the ultimate dumbness, and it beats everything Clipper does — if members are not needed.

**Fragment caching — with a large share of signed-in visitors.** If most visitors are signed in, the guest cache barely works. Then it is better to cache the page body without the user block and insert the block on send. Clipper does this for the form-protection token (it is marked in the body and substituted), but not for the name and rights.

### How moderation would break the cache

If a hidden message were visible to its author but not to others, the page would stop being the same for all guests of a theme: an author who signed out is a guest too. The cache would have to be either switched off for pages with discussions or given a "who is looking" key part. This illustrates the axis: one moderation feature breaks a subsystem that seemingly has nothing to do with moderation.
