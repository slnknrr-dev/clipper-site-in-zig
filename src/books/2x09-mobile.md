## Mobile pages of 2003

### What there was

In 2003 "the mobile internet" meant a phone with a tiny screen and a slow link. Three worlds:

- **WAP and WML** — a separate markup language for phones, "decks" of "cards", a gateway of its own between the phone and the site;
- **i-mode and cHTML** (Japan) — a cut-down HTML without tables or frames;
- **PDAs** (Pocket PC, Palm) — small browsers that understood ordinary HTML with limitations.

Common to all: the mobile version is **separate pages**, not the same pages rearranged by styles. The server decided what to send by address (`wap.site`, `/m/`) or by the `User-Agent` header.

### What Clipper does

The mobile version is turned on with the parameter `m=true` and is carried through all links. Without the parameter the server decides by `User-Agent`. The mobile layout is one column, large text, menu columns moved down.

This is closer to the 2003 approach than to the modern one: the server sends different markup rather than one for everyone with media queries. For the server this means doubling the page variants, but each variant is simple and each is cached at its own address.

### Where Clipper steps out of the era

Every Clipper page has the line:

```
<meta name="viewport" content="width=device-width, initial-scale=1">
```

This is a 2007 invention (Safari on the iPhone). Without it a modern phone shows the page as on a 980-pixel-wide screen shrunk three times. Old browsers simply ignore it, so it breaks nothing. It is a concession to today's phones, and it costs one line.

### The lesson for the server

A separate mobile page — the server decides, the client displays. One page with styles for all screens — the client decides, and the server does not know what will be shown. The first is easier to verify: each variant is its own document that can be fetched and compared. Clipper's contract checks mobile pages the same way as ordinary ones.
