# TODO

Status of the URL shortener. Phase 1 is a single app server with a single Postgres database,
handling concurrent requests. Scaling out comes later.

## Done

- [x] Postgres (Fluent) with environment-based config (`DATABASE_URL`, `PORT`, `BASE_URL`)
- [x] Schema: `url_records` (`shortCode` PK, unique `urlHash`) and `counters`
- [x] 7-character, zero-padded Base62 short codes from a counter that starts at 0
- [x] Atomic counter reservation (`UPDATE ... RETURNING`, block size 1000, one refill in flight)
- [x] Idempotent create: normalized URL, SHA-256 hash, unique constraint, `23505` race handling
- [x] Unit and integration tests on a separate `urlshortener_test` database, cleaned up after each test

## Next (small, current phase)

- [ ] Refuse to run integration tests unless the database name ends in `_test`
- [ ] Tests for the redirect, lookup and delete endpoints
- [ ] Atomic hit counter: `UPDATE ... SET "hitCount" = "hitCount" + 1` (today it is read-modify-write and can lose counts)
- [ ] Validate the short-code format (exactly 7 Base62 characters) before querying the database
- [ ] Push the repo: switch to a GitHub account with write access, then force-push (the first commit was amended after it was pushed)

## Deferred by decision

- [ ] **Authentication and ownership (last phase of development)**
  - [ ] Authenticate `DELETE /api/url/:code` (it is open to anyone today)
  - [ ] Decide global vs per-owner dedupe (`unique(ownerId, urlHash)`)
  - [ ] Soft delete (`deletedAt`)
- [ ] **Code obfuscation, when scaling the DB**: pass the counter through a keyed Feistel permutation over
      [0, 62^7) before Base62 encoding, so codes are not sequential or guessable. Keep the key in a secrets
      manager and never rotate it.

## Hardening backlog

- [ ] Redirect path
  - [ ] Make the redirect read-only
  - [ ] In-process LRU cache, then Redis, with short-lived caching of not-found results
  - [ ] Choose 301 vs 302/307 deliberately (301 is cached by browsers and hides clicks from analytics)
  - [ ] `Cache-Control` headers and a CDN in front
- [ ] Hit counting: batch counts in memory/Redis, or emit click events to a queue; keep `hitCount` as an eventually consistent rollup
- [ ] Rate limiting: creates per API key and per IP; redirects at the edge or WAF
- [ ] Observability
  - [ ] Structured logs with request IDs
  - [ ] Prometheus metrics: latency, cache hit rate, creates per second, counter refills
  - [ ] Tracing
  - [ ] Separate liveness and readiness endpoints (readiness checks the database)
  - [ ] Graceful shutdown that flushes pending hit counts
- [ ] URL validation
  - [ ] Reject links to private IP ranges, `localhost` and the service's own domain (redirect loops)
  - [ ] Convert IDN hosts to punycode
  - [ ] Optional malicious-URL check (for example Google Safe Browsing) on create
- [ ] Link lifecycle: expiry (`expiresAt`), custom aliases (with reserved-word checks)
- [ ] Load test the redirect path (`k6` or `wrk`) before sizing infrastructure
- [ ] Size the Postgres connection pool; keep future migrations as separate, ordered files

## Scale phase

- [ ] Multiple stateless app instances behind a load balancer (the atomic counter is already safe for this)
- [ ] Postgres primary with read replicas
- [ ] Redis for caching
- [ ] CDN in front of redirects
- [ ] Multi-region
