## Federation: sign-in from neighbouring sites

### Fork

A member of one Clipper site wants to enter another under their own name, without registration or a password.

### Paths

1. **A shared member database** for all sites.
2. **OpenID Connect / OAuth**: one site is the identity provider, the other the relying party.
3. **ActivityPub**: full federation where sites exchange not only sign-in but messages.
4. **A one-time ticket and a back-channel question**: a simple protocol of one's own.

### Choice

Path 4.

1. On the `/fed` page a member of site A clicks "go to B". A creates a one-time ticket (lives 2 minutes, issued for B, its hash kept in the store) and sends the browser to `B/fed/in?from=A&ticket=…`.
2. B itself asks A: "is this ticket genuine?". A burns the ticket and answers with the member's number and name.
3. B creates a guest "name@A" and a session.

The password never leaves its own site. The guest has no password, their session expires after 45 minutes of inactivity, and it does not federate further. Who may come in here and where one may go from here is decided by the administrator — with a table or the file `FEDIVERSE.csv`, which is reread while the server runs.

Why: it is a minimal protocol solving one problem. It can be read in full in a minute. It needs only one outgoing request and one ticket table.

### Dead ends

**A shared database (path 1)** contradicts the idea of portability: a site stops being independent, and a database failure closes all sites at once.

**A ticket without the back-channel question** (a signed ticket that B checks itself with A's key). Removes the outgoing request but needs key exchange and revocation. For friendly sites that know each other from a list, the back-channel question is simpler and no worse.

### Better — under other conditions

**OpenID Connect — if the neighbours are not only Clippers.** A standard protocol would allow sign-in through any provider site. The price — JWT signatures, discovery, RSA keys (absent from the standard library) — is more than all of Clipper's federation.

**ActivityPub — if a shared feed is needed.** That is the next step of the axis: the site starts receiving messages from other sites, storing them, moderating someone else's content. That is no longer "sign-in" but another product.

### Price

The question to the neighbour is an outgoing request right inside the event loop, with an 8-second timeout: during that time the process serves nobody. The Windows XP build has no outgoing https (the standard library's TLS client uses a time function that appeared in Windows 8), so federation there works only with http sites. The server does not ask an unfamiliar site questions at addresses of this machine or internal networks. Sign-in between two sites over https has not been checked in practice: testing was done on one machine over http.
