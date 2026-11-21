## How Flibusta was studied

Before building a library it pays to look at one that survived. The study was short and narrow: the site was viewed the way any visitor sees it — pages, addresses, response headers. Nothing beyond that: neither internals nor contents. The notes are dated early November 2026.

### What is visible from outside

The engine is Drupal 6: paths like `sites/default/files`, form fields `form_build_id` and addresses `node/N` give it away. The encoding is UTF-8. The home page is about 38 KB of markup, a book page about 29 KB. One concatenated stylesheet and one concatenated script.

So a site that carried heavy load for years is built on an ordinary mid-2000s engine. That is the first and most useful observation: resilience came not from exotic technology but from the decisions around it. For the study this means the choice of engine is not the main fork. The main ones are data, addresses and access.

### Address scheme

| address | what it is |
| /b/N | book |
| /b/N/read, /b/N/fb2, /b/N/epub | reading and download |
| /a/N | author |
| /s/N | series |
| /g/N | genre |
| /forum/N, /blog/N, /node/N | forum, blogs, news |
| /opds | catalog for e-readers |
| /sql/, /daily/ | database dumps and daily archives |

This scheme outlives everything. A book's address does not depend on its title, author, genre or how the site works inside. It can be dictated over the phone and needs no transliteration.

Clipper took the principle further: one letter per kind of entity, and the sign of the number tells related kinds apart. `/b/5` is a book, `/b/-5` a series. `/u/5` is a member, `/u/-5` an author. `/c/5` is a person's quotes, `/c/-5` a character's.

**A dead end that was avoided:** addresses with words (`/book/geroy-nashego-vremeni`). They are pretty until the book is renamed, until a second book with the same title appears, and until the title is in a language nobody knows how to transliterate. A number has none of these three problems.

**What would be better:** numbers have a flaw too — they reveal the library's size and the order of additions. If that matters (say, for closed sections), short random identifiers are used. For an open library the flaw is negligible.

### Resilience as a set of small things

The home page has a section about access: onion, I2P, alternative DNS, mirrors, OPDS, dumps, torrent. Each thing alone is small. Together they mean the library has no single point whose failure cuts off access to the books.

For the architecture this yields a requirement that is easy to miss: the data must be portable without the server. If the catalog is copied as one file and members' records as another, a mirror goes up with a copy command. In Clipper this is literally so: `library.N.snap` and `clipper.journal`.

### What is on a book page

Besides the title and formats — the series with a subscription, the date added, the annotation, the number of recommendations and reviews with ratings. Half the page is about other readers.

The conclusion that defined Clipper's contents: community features are not an add-on to the catalog but half the product. They cannot be bolted on the side, because then storage will have been designed for data that is only read. That is the axis around which the whole book is built — more on it two pages on.

### What the study did not give

From outside you cannot see how the site stores books, how search works or what happens on upload. Everything Clipper does inside is its own decision, not a borrowed one. Three things were taken: numbered addresses, data portability and the place of the community on the page.

## What was taken from other sites and from the mockup

Clipper has four themes, and each reproduces the layout of a real early-2000s site: flibusta.is, samlib.ru, proza.ru and nepomn.ru. They were studied as layout: flibusta.is — the column of blocks on the right and the row of letters above lists; samlib.ru — the dense author page; proza.ru — the header and footer with the site's address; nepomn.ru — the grey frame around white cells and the page title as a small table. What is taken is the arrangement, the order of elements and the sizes; names, logos and stylesheets are written anew.

### The mockup as an executable specification

When a server is written in a systems language while the site is still being invented, every change of intent is expensive, and the intent starts bending to what has already been written. The mockup breaks that link: in it the site is invented cheaply and completely.

The main benefit showed up later: the mockup became the thing to compare against. "Does the server answer `/b/2/-1-1` correctly?" stopped being a matter of taste. The contract test has about 1200 such cases, and a run takes seconds. Its data is a test fixture that the test puts into the folder itself: the program contains none of it.

**Dead end:** a text specification. It diverges from the code on day one and says nothing about it. A reference program diverges loudly.

**Price:** the mockup is authoritative only in what is visible from outside, and it is frozen. Everything the server does beyond the mockup — federation, panel settings, upload formats, built-in books — is not covered by the contract and needs its own tests. And where the server deliberately departs from the mockup, the test has to be edited and the reason explained.
