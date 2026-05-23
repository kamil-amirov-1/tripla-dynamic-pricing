# Dynamic Pricing Take-home Assignment Solution

## Overview

A caching layer in front of Tripla's dynamic pricing model. The model is expensive
to run and has a hard limit of 1,000 API calls/day. The goal was to serve 10,000
user requests/day without blowing that budget, while always serving rates that are
**no older than 5 minutes**.

The scaffold already had the endpoint ready and calling the model on every request.
My job was to make that sustainable.

---
## Why I chose batch-all caching

My first instinct was to cache each `(period, hotel, room)` combination separately —
fetch on miss, cache for 5 minutes, done. Then I did the math:

- 4 seasons × 3 hotels × 3 rooms = **36 unique combinations**
- 24h/5min = **288 expiry windows per day**
- If each combination expires independently: 36 × 288 = **10,368 upstream calls/day**

That is 10x over the 1,000/day limit, even with caching enabled.

The model API supports **batch requests** - so we can send multiple combinations in one
call. I changed the strategy: on any cache miss, fetch **all 36 combinations** in
one call and cache each returned rate for 5 minutes. In the no-contention case, that
is **288 calls/day**, with plenty of headroom.

---
## Why Redis and not memory store

I considered `memory_store` first. It is simpler because it needs no extra service.
It works for a single Rails process, but it is not a production-safe coordination
mechanism.

Puma can run multiple worker processes in production, and each process has its own
memory. If one worker fetches fresh rates, the other workers cannot see that cache
entry. Horizontal scaling has the same problem across containers.

Redis gives the app one shared pricing cache. All workers and app containers
read from and write to the same store, so one worker's fresh rates benefit all others.

---
## How cache misses are handled

Each rate is stored under its own Redis key — `pricing:rate:{period}:{hotel}:{room}`
- with a 5-minute TTL.

When a request arrives for a combination that is not in Redis, the service fetches
all 36 combinations in one upstream batch call, writes each returned rate as its own
key, and logs any combinations absent from the response. Requests for returned
combinations succeed. Requests for missing combinations get a 503 - the rate is unavailable right now (the next 
refresh cycle might recover them). So a partial upstream failure does not affect users asking for rates that were returned.

At the stated load (10,000 req/day ~ 0.12 req/sec), I chose not to add a refresh lock
in this version. That keeps the implementation smaller for the assignment while still
meeting the budget in normal operation - one batch refresh per 5-minute window is about
288 upstream calls/day.

The tradeoff is that concurrent cold-cache misses can trigger duplicate batch calls.
Those duplicates do not affect correctness because all callers write fresh rates with
the same TTL, but they can increase upstream usage during bursts or deploy restarts.

todo: For a higher-concurrency deployment, the next hardening step is a Redis `SET NX` lock
around batch refresh.

---
## Architecture

![diagram.png](diagram.png)

The main components:

- **`PricingController`** - validates params, calls the service, renders the response.
- **`PricingService`** - orchestrates the above, maps errors to user-facing messages,
  logs full exception class and message server-side for unexpected failures.
- **`RateCacheService`** - owns the cache logic. Reads the requested per-combination
  key from Redis. On miss, fetches all 36 combinations in one upstream batch call,
  writes the returned rates as separate keys with a 5-minute TTL, and logs missing
  combinations.
- **`RateApiClient`** - HTTP wrapper around the upstream model. Handles batch
  requests, split timeouts, and normalises all network errors into `RateApiError`.

---
## Error handling

I split errors by whose fault they are:
- **400** - the client sent invalid or missing params. Caught before the service is
  called.
- **503** - everything server-side: upstream timeout, upstream error, Redis
  unavailable, a requested combination absent from the upstream response, or an
  unexpected internal error.

For now I specifically chose not to fall back to direct upstream calls when Redis is down.
It feels like a helpful degradation, but it would bypass the rate-limit protection
and risk exhausting the daily quota. A 503 with a clear error message is more honest. (TBD)

---
## Alternatives considered

**Proactive cache warming** - a background job refreshes all 36 combinations every
~4.5 minutes so the cache is always warm and no request ever waits for an upstream
call. Cleaner user experience, same API budget. I left it out because at ~0.12 req/s
average load the miss latency is infrequent and acceptable, and adding a scheduler
(sidekiq, cron) is operational complexity I did not want to take on without a clearer
need. It is the most obvious next step if latency becomes a concern.

**file_store** - works across Puma workers on the same host, needs no extra service.
Does not survive multi-container deployments. Redis requires a small amount of local
setup but is the standard for shared cache in containerised Rails services.

**Single-key snapshot approach** - store all 36 rates in one Redis key and look up
the requested combination in memory. Simpler to implement. Rejected because partial
upstream responses make the snapshot semantically ambiguous: is the catalog fresh,
degraded, or incomplete? Per-combination keys make that explicit — each key either
exists (fresh rate) or is absent (genuinely unavailable), with no ambiguity about
what the stored data represents.

**race_condition_ttl** - Rails can serve stale cached data for a short grace window
while regenerating a value. I eliminated it, the assignment says a rate is valid for
5 minutes. Serving a rate beyond that window would violate the core requirement.

---
## Known limitations

- **No proactive warming** - first request after each 5-minute window pays the
  upstream latency. (TBD)
- **No refresh lock** - concurrent cache misses can trigger multiple simultaneous
  upstream calls. At the stated load this is acceptable, but at significantly higher
  concurrency a Redis SET NX lock would eliminate redundant calls. (TBD)
- **No retry on upstream failure** - a single error returns 503 immediately.
  Exponential backoff with a small retry count would be a sensible addition. (TBD)
- **Single Redis instance** - no cluster HA. An outage returns 503 and
  is logged; it does not degrade to unprotected upstream calls. (TBD)
