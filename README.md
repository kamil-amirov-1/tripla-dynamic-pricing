# Dynamic Pricing Take-home Assignment Solution

## Reviewer notes

The core design choice is batch refresh. Since there are only 36 valid combinations,
one upstream batch call refreshes the whole catalog for a 5-minute window.

The Redis lock prevents cold-start stampedes, and missing rates are cached as a
5-minute negative result so one absent combination does not repeatedly trigger refreshes.

A Sidekiq cron job warms the cache every 4 minutes so users do not wait for an upstream
call after the first window. The existing Redis lock ensures only one refresh runs at a time.

---
## Overview

A caching layer in front of Tripla's dynamic pricing model. The model is expensive
to run and has a hard limit of 1,000 API calls/day. The goal was to serve 10,000
user requests/day without blowing that budget, while always serving rates that are
**no older than 5 minutes**.

The scaffold already had the endpoint ready and calling the model on every request.
My job was to make that sustainable.

---
## Why I chose batch-all caching

My first instinct was to cache each `(period, hotel, room)` combination separately -
fetch on miss, cache for 5 minutes, done. Then I did the math:

- 4 seasons × 3 hotels × 3 rooms = **36 unique combinations**
- 24h/5min = **288 expiry windows per day**
- If each combination expires independently: 36 × 288 = **10,368 upstream calls/day**

That is 10x over the 1,000/day limit, even with caching enabled.

The model API supports **batch requests**, so I changed the strategy: on any cache
miss, fetch **all 36 combinations** in one call and cache each rate for 5 minutes.
Request-driven refresh alone would cost about 288 calls/day. With proactive warming
every 4 minutes the warmer uses about 360 calls/day - still well below the 1,000/day limit.

---
## Why Redis and not memory store

`memory_store` works for a single process but not across Puma workers or containers -
each has its own memory, so one worker's cached rates are invisible to the others.
Redis is a shared store that all workers and containers read from and write to.

---
## Why a refresh lock

Average load is fine, but a deploy restart can start all workers with an empty cache. 
Without a lock, 10 concurrent cold misses fire 10 upstream calls. A Redis `SET NX EX` lock
ensures only one process fetches at a time - everyone else waits, then reads from
the populated cache. One call per window instead of N.

The release uses a Lua script instead of a plain `DELETE`. If the holder crashes and
the TTL expires, another process can acquire the lock before the cleanup runs - a
plain `DELETE` would wipe it. The Lua script checks the token first, so only the
original holder can release its own lock.

---
## Why proactive warming

The request path refreshes the cache on demand, but the first request after a 5-minute
window pays upstream latency. A Sidekiq cron job refreshes the catalog every 4 minutes,
so rates are already warm before they expire in normal operation.

This uses about 360 upstream calls/day, still below the 1,000/day limit. The same Redis
lock is shared by both the warmer and user-triggered refreshes, so only one fetch can
run at a time.

---
## How cache misses are handled

Each rate is stored under its own Redis key - `pricing:rate:{period}:{hotel}:{room}`
- with a 5-minute TTL.

On a cache miss the service acquires the lock, fetches all 36 combinations in one
batch call, writes each returned rate, and releases the lock. Only combinations in
`PricingCatalog` are written - unknown rows are discarded. Concurrent misses wait for
the lock holder then read from cache. If the lock holder writes neither a rate 
nor a missing marker, waiters raise a 503 rather than silently returning nil.

Combinations the upstream did not return are cached as missing for the same 5-minute
window and return 404. This avoids repeatedly calling upstream for a temporarily
unavailable combination. A partial response does not affect users asking for rates
that were returned.

---
## Architecture

![diagram.png](diagram.png)

- **`PricingController`** - validates params, delegates to `PricingService`, renders the response.
- **`PricingService`** - runs the service, maps errors to user-facing messages and HTTP status codes.
- **`RateCacheService`** - owns the cache logic. On miss, acquires a distributed lock, fetches all 36 combinations, writes each rate with a 5-minute TTL, and releases the lock.
- **`RateApiClient`** - HTTP wrapper. Handles batch requests, split timeouts, and normalizes all errors into `RateApiError`.
- **`PricingCatalog`** - single source of truth for valid periods, hotels, and rooms. Used by the controller for validation and by `RateCacheService` to build the batch request and filter unknown rows.
- **`CacheWarmerWorker`** - Sidekiq job that runs every 4 minutes via sidekiq-cron, proactively refreshing all 36 combinations before the 5-minute TTL expires.

---
## Error handling

I split errors by whose fault they are:
- **400** - invalid or missing params. Caught before the service is called.
- **404** - valid params but the rate was not returned by the upstream in the latest batch.
- **503** - server-side failure: upstream timeout, upstream error, Redis unavailable, or an unexpected internal error.

I chose not to fall back to direct upstream calls when Redis is down. It feels
helpful but bypasses the rate-limit protection and risks exhausting the daily quota.
A 503 is more honest.

---
## Alternatives considered

**Request-only refresh** - cache on demand, no background job. Simpler, but the first
request after each 5-minute window pays upstream latency. Replaced by proactive warming.

**file_store** - works across Puma workers on the same host but not across containers.
Redis is the standard for shared cache in containerized Rails services.

**Single-key snapshot** - store all 36 rates in one Redis key. Simpler, but rejected
because partial upstream responses make the snapshot ambiguous. Per-combination keys
are explicit - each key either exists or is absent.

**race_condition_ttl** - Rails can serve stale data for a short grace window while
regenerating. Eliminated - the assignment says rates are valid for 5 minutes. Serving
beyond that would violate the core requirement.

---
## Observability

I added structured logging because the main risk in this service is not CPU or database load, but upstream usage and cache behavior.

Request logs are compact single-line logs via Lograge. The pricing service also logs cache hits 
and misses, refresh lock acquisition and waits, upstream refresh duration, and missing combination counts. 
In production, these are the signals to alert on before upstream quota or availability becomes a user-facing problem.

---
## Known limitations

- **No retry on upstream failure** - a single error returns 503 immediately. Retries are intentionally omitted - on a 1,000/day quota, retrying a failed call risks doubling upstream usage during an outage.
- **Single Redis instance** - no cluster HA. An outage returns 503 and does not degrade to unprotected upstream calls.

---
## How to run

```bash
docker compose up -d --build
```

This starts the Rails app, rate-api, Redis, and Sidekiq. The Rails app is available on `http://localhost:3000`.
Example requests:

**200:**
```bash
curl "http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom"
```
```bash
curl "http://localhost:3000/api/v1/pricing?period=Winter&hotel=FloatingPointResort&room=RestfulKing"
```
**400:**
```bash
curl "http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort"
```
---
## How to test

```bash
docker compose exec interview-dev ./bin/rails test
```

Tests use an in-memory cache store - no Redis required to run the test suite.

---
## Environment variables

- `RATE_API_URL` - URL of the upstream pricing API. Default: `http://localhost:8080`
- `RATE_API_TOKEN` - Auth token for the upstream API. Default: `04aa6f42aa03f220c2ae9a276cd68c62`
- `RATE_API_CONNECT_TIMEOUT` - TCP connection timeout in seconds. Default: `3`
- `RATE_API_READ_TIMEOUT` - HTTP read timeout in seconds. Default: `10`
- `REDIS_URL` - Redis connection URL. Required in production. Default: `redis://localhost:6379/0`
- `REDIS_CONNECT_TIMEOUT` - Redis TCP connection timeout in seconds. Default: `1`
- `REDIS_READ_TIMEOUT` - Redis read timeout in seconds. Default: `1`
- `REDIS_WRITE_TIMEOUT` - Redis write timeout in seconds. Default: `1`
- `REDIS_RECONNECT_ATTEMPTS` - Redis reconnect attempts on connection failure. Default: `3`

---
## AI usage

I used AI assistance during this assignment as a coding and review aid.

My process was:
- I read the assignment requirements and upstream API documentation.
- I made the core design decisions: batch-all refresh, Redis-backed shared cache,
  refresh locking, negative caching for missing combinations, and fail-closed behavior
  when Redis or the upstream API is unavailable.
- I used AI to help draft code, tests, and README wording faster.
- I reviewed the generated code line by line, adjusted the design when needed, and
  only kept changes that matched my understanding of the requirements.
- I ran the test suite in Docker and manually checked the implementation against the
  assignment constraints before submission.

In short, AI was used as a pair-programming assistant. The architecture, tradeoffs,
final code review, and submission decisions are mine.
