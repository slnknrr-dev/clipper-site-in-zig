## Security: input, sessions, TLS

### Hostile input

Everything that comes from outside — a request, a form, a book file — may be an attack. The fork here is not "validate or not" but "how to make sure nothing unvalidated gets through".

Paths:

1. checks at the place where data is used;
2. strict parsing at the boundary: beyond it the program works only with parsed data;
3. parsing plus a budget: the parser cannot spend more than a preset amount.

The choice is 2 and 3. HTTP is parsed strictly: headers no longer than 8 KB, a form body no more than 64 KB, a book upload up to 50 MB streamed to a file. Parsing EPUB, PDF and DjVu runs under a shared budget of 384 MB per book: a one-megabyte compressed file may decompress into gigabytes, and every decompression first asks the budget for permission.

The proof is the hostile-input tests: 60 thousand corrupted requests, 50 thousand forms and ranges, about nine thousand requests through the whole application, including uploads of corrupted books. No panic, no 500, no leak. One real bug was found exactly this way: a request for part of an empty file (`Range: bytes=-5`) caused an overflow while computing the response header and stopped the server.

**Better:** runtime checks turn a bug into a stop rather than memory corruption, but a stop by one request is still denial of service. It would be better to parse books in a separate process: if parsing crashes, the server lives.

### Passwords and sessions

Passwords are stored as Argon2id hashes. A session is a random value in a cookie; the server keeps only its hash, so the store's contents cannot be used to sign in. All forms are protected by a cross-site request forgery token. The sign-out page shows all sessions with addresses and closes any one or all at once.

Sign-in of the built-in administrator `/u/0` works only from the same machine and only if the password is set by a startup flag. A plain-text password in a flag (`-pwd`) is visible in the process list; for machines where that matters there is `-phc` — a hash string printed by `clipper hash`.

**Dead end:** a session in a cookie with no server-side storage (a signed token). It cannot be revoked before it expires — and "sign out everywhere" is a must for a site where a member may have signed in from someone else's computer.

### TLS

The fork: answer https itself or sit behind a reverse proxy.

The Zig 0.14 standard library has a TLS client but no server. Clipper built a TLS 1.3 server from standard library primitives: X25519 key exchange, AES-128-GCM and ChaCha20-Poly1305 ciphers, HKDF key derivation, ECDSA P-256 and Ed25519 signatures. About 860 lines. TLS 1.3 only, without session resumption or early data: every missing feature is code you cannot get wrong.

The session core works on bytes and knows nothing about sockets. That is why key derivation is checked against reference vectors (RFC 8448), a record is encrypted and decrypted in a test, and a corrupted client hello does not crash the parser. From outside the server was checked with `curl` and `openssl s_client`.

**The price is the biggest in the project.** This is a cryptographic protocol written by someone who is not a cryptographer and never audited by a third party. Compatibility with two programs proves the protocol works, not that it does not leak the key through response timing. RSA keys are not supported at all.

**Better** for a site on the open internet: a reverse proxy with ordinary TLS in front of Clipper. The built-in TLS is justified by the "nothing foreign" frame and is useful in internal networks and for development.
