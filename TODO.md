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
- [x] Integration tests refuse to run against any database whose name does not end in `_test`
- [x] Tests for health, redirect, lookup and delete endpoints
- [x] `Cache-Control: no-store` on redirect and metadata lookup (including their 404s); redirect stays a 307

## Done: redirect cache and hit counting (single server, in-process)

- [x] `RedirectCache` actor on a reusable generic `LRUCache`: bounded LRU (default 100k entries, 1h TTL), 30s negative cache, single-flight loads,
      write-through on create, invalidate on delete, injectable clock for tests
- [x] `HitCounter` actor (wired to the app lifecycle and the redirect): count hits in memory, flush every 5s (or at 10k pending codes) with one additive batched
      `UPDATE ... FROM (VALUES ...)`; retry on failure; flush on graceful shutdown (accepted: a hard crash can lose up to 5s of counts)
- [x] Redirect path: cache, then single-flight DB load, then in-memory hit increment, with no DB call on a cache hit
- [x] Metadata lookup adds this process's pending count to the stored `hitCount`
- [x] Config: `CACHE_MAX_ENTRIES`, `CACHE_TTL_SECONDS`, `NEGATIVE_CACHE_TTL_SECONDS`, `HIT_FLUSH_INTERVAL_SECONDS`, `HIT_MAX_PENDING_CODES`
- [x] Both sit behind small protocols (`RedirectCaching`, `HitStore`) so a Redis-backed version can be added later
- [x] Tests: cache hit without DB, delete invalidation, LRU/TTL/negative expiry, single-flight, 1,000 concurrent
      redirects give exactly 1,000 hits, failed flush retries, flush on shutdown

## Next (small, current phase)

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
- [ ] Redis for caching (swap in when running more than one app instance, so deletes and hit counts are shared)
- [ ] CDN in front of redirects
- [ ] Multi-region
