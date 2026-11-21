## Method: frame, fork, measurement, price

R&D in this project is not a big word but a cycle repeated for every decision.

- **Frame.** First — hard constraints and the single external interface. Until it is clear what cannot be sacrificed, every decision looks good.
- **Fork.** Several options are set side by side, criteria are named, one is chosen. The rejected ones are not thrown away: they are recorded along with the reason.
- **Measurement.** A decision ends in a test or a measurement, not in prose. "Faster" without a number is not a result.
- **Price.** For every decision it is stated what was given up for it and when it will stop being right.

### A negative result is a result too

A good example is text compression in the first version. The hypothesis: moving punctuation into a separate stream would compress text better. Checked — it got worse by 5.6–9.5%. A custom order-3 statistical model with an entropy coder turned out 11% denser than zstd on 4 KB frames within its domain, but 13% worse outside it and 30 times slower to decompress. Both hypotheses are dead ends, and both were written down with the numbers: the next researcher will not spend a week on them.

### Dead end, accepted and better

The book distinguishes three kinds of assessment, and it helps not to mix them up.

A **dead end** is a path that does not lead to the goal with any reasonable effort: it either contradicts the frame or was checked and gave no result. Example: a garbage-collected server under the requirement "zero allocations per request".

**Accepted** is a path chosen under this frame and these resources. It may be worse than the best, but the best costs more than the project can give. Example: a journal without compaction.

**Better** is a path that would be of higher quality if the frame or the resources were different. It is worth describing even if you do not intend to take it: that shows where the accepted decision will start losing. Example: an LSM tree instead of a journal for a site with tens of thousands of writes a day.

### Three attempts as one experiment

The first version was a study of the scale limit: a million books, 2 GB of memory, faceted search. It answered "is it possible" and showed what it costs in complexity.

The mockup was a study of the product: what the site should be like for people.

The main version tests a hypothesis: if the scale is narrowed to one community's library while keeping all the social functionality — how much simpler does the server become?

The answer, running ahead: noticeably simpler, but not where expected. Catalog storage got much simpler. But writing — what members write — stayed almost as complex as it would be with a million books. A server's complexity is set not by the library's size but by what can be done on the site. That is the next page.
