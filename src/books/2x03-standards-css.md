## CSS: what worked and what Clipper did not keep to

### What there was

CSS1 — 1996: fonts, colors, margins, borders. CSS2 — 1998: positioning, media types (`screen`, `print`), descendant and attribute selectors. By 2003 CSS1 worked almost everywhere, CSS2 partly: IE6 did not understand child (`>`) and attribute selectors, `position: fixed` or `min-width`; IE5 had its own box model.

The rule of the era: style is an enhancement, not a foundation. If a stylesheet did not load or was not understood, the page is still readable.

### What Clipper does

Theme layout is done with tables and attributes in the markup: widths, alignment. That renders everywhere.

On top come styles: fonts, colors, block borders. There is one stylesheet per theme and mode, `/css/theme-mode.css`, with a long cache lifetime. One theme's markup is the same for all modes — light, dark and "by time of day".

Theme headers are drawn with background strip images: a gradient is a BMP as tall as the header and one pixel wide, repeated horizontally. The server draws such a BMP itself at `/g/height/colors.bmp`. That is how it was done in 2003, because CSS had no gradients.

### Where Clipper steps out of 2003 — honestly

Mode colors are set with CSS variables (`var(--fg)`) and the `prefers-color-scheme` media query, which picks the light or dark mode by the system setting. These are technologies of 2016–2019.

What a 2003 browser sees: it does not understand a declaration with `var()` and drops it. And in Clipper almost all theme colors are set through variables — backgrounds, text, links, borders; color attributes in the templates are few. What remains is the table layout, fonts, margins and the header strip images, while the colors become the browser defaults: black text on white, blue links. The page reads and works, but the theme is recognized by its structure rather than its look, and there is no dark mode.

Why it was done this way: switching modes without variables requires either separate markup per mode (then the page cache multiplies by four) or a separate full stylesheet for every theme-and-mode combination, repeating all the rules. Variables gave "one markup, one small palette file". This decision was made for the server's sake, and it breaks the frame of the era.

**Better** would be to generate a full stylesheet without variables for every "theme, mode" pair — the server builds these files at startup anyway. Then the markup would stay single, and 2003 browsers would get the correct light-mode colors. The "by device" mode would still be unavailable to them — it did not exist then. This is a small improvement, and it is recorded in the list of things not done.

### The lesson for the server

Styles are the data that changes least often on a site. They should be served as a separate file with a long cache lifetime and not embedded in every page. Then a page is content only, and the smaller it is, the faster it is to build, compress and send. Clipper does exactly that: a page is 5–30 KB, styles are sent once per visitor.
