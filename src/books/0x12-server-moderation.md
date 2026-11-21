## Rights, moderation and what Clipper lacks

### What there is

A member has six rights: forum, comments, drafts, quotes, uploading books and the "staff" mark (staff have their own set of allowed upload formats). Rights are stored as one byte in the account; a check is one "and" operation. A member can be blocked. Twelve switches in the panel turn whole parts of the site off.

Above that are the startup flags `-M`, `-R`, `-G` and `-N` (page 0x16): for each of the five sections — everyone writes, only moderators write, read-only, whether it is open to guests, whether the section exists at all. A moderator here is a member with the "staff" right. Section rules are five bits per kind of restriction, and the check on a request is the same "and" operations: the "who may do what" decision grew a little wider but did not become a state machine.

The site is run by the built-in administrator `/u/0`, but not in the usual way. Their sign-in is set by startup flags (`-l`, `-pwd`, `-phc`) and works only from the same machine. This is not a way to run the site but a way to set it up: sign in locally, create a member and give them rights. Without a password in the flags `/u/0` cannot be signed into at all.

### Why so

A built-in administrator with a password in the database is a classic hole: a default password, brute force, a database leak. The "only from this machine" restriction removes it from the attack surface: from outside, `/u/0` is just a page. And setting the password by flag rather than by a settings file makes the administrator explicit: if the server is started without a password, there is none.

Why only six rights and not roles. A role-based design raises the question "who may grant the role that grants roles", and it has to be answered in code. Six independent bits answer everything a community of a few thousand people needs.

### What is missing — and why that is a decision

No premoderation, reports, hiding of individual messages or moderator action log. Per-section rights exist only in a coarse form — "only moderators write" for a whole section, with no rights for an individual forum or topic. As the axis showed (page 0x05), each of these lifts the server a step: a message state machine, a "who sees what" decision on every view, secondary indexes for queues, a broken cache.

### Paths, if moderation is needed

1. **Deletion instead of hiding.** A moderator deletes a message; nothing has to be shown selectively. The dumbest path, and often enough for a small community. Price — it cannot be undone.
2. **A "hidden" flag without exceptions.** Nobody sees hidden content except `/u/0`. The cache does not break: the page is the same for guests. One bit in the value and one check on display.
3. **The full model**: states, an exception for the author, a queue, a log. Breaks the cache, needs indexes.

**The best for Clipper** is path 2. It gives reversibility and keeps the main property: the guest page is the same for everyone. Path 3 is worth taking only when the community has grown so much that there are several moderators who need to see each other's work.

### Anonymous boards — moderation by time

Boards that auto-delete a thread after an hour, six hours or a day are moderation too, only the dumbest possible kind: everything disappears by itself. That is no coincidence. A conversation that will not remain does not need to be moderated as carefully as an archive. The price is shifted onto time, and the server pays for it only with a deadline check on display and an occasional cleanup.
