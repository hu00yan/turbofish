# Results: Turbofish (MinIO + local metadata service) vs Qdrant

> **版本注记（先读这段）**：本文件是一次真实运行的历史记录，测的是 commit
> `291b260`。该 commit 早于 W1–W8（异步 store、L0 单文件 slab、group commit、
> 独立 compactd、`metad`）。文中的写入数字（942 docs/s、92 S3 请求/1000 文档、
> 其中 84 个 `PutObject`）属于 **legacy 多对象写路径**，不是现在 `cmd/serve`
> 的线上路径。用 `cmd/bench1m` 加 `BENCH_WRITE_SLAB=1` 才能测到线上路径；
> 当前口径见 [`docs/TURBOPUFFER.md`](../docs/TURBOPUFFER.md) §5.1。
> 查询侧数字（warm p50 0.66 ms、冷窗 31 次 GET、recall 0.945）仍代表当时的
> 架构，重测之前不要当作当前值引用。

This file reports one real run of `perf/run_compare.py`. All numbers below are
read from
[`results/compare-20261115T101916Z-33642.json`](results/compare-20261115T101916Z-33642.json),
which has `"errors": []`. Nothing here is hard-coded or estimated.

Run window: **2026-11-15T10:19:16Z → 2026-11-15T10:28:57Z** (9m41s wall).
The JSON's `started_at` / `finished_at` and per-phase values are authoritative;
the wall time includes dataset generation, both Turbofish ingests, tuning,
warm/cold measurement and storage capture.

## 1. Provenance and environment

| Item | Value |
| --- | --- |
| Turbofish commit | `291b260a43829b296f67ed48ff20d715b7a7e5ee` (pinned clone in the VM) |
| Turbofish binary | `_build/native/release/build/cmd/serve/serve.exe` |
| Binary SHA-256 | `9aa90bf7cd4dfc2f392fca3e2111461d5098e395641d161591957c3c4ef174d5` |
| Metadata service | `cmd/metad` built from the same commit; SSD-backed local store under the run work dir |
| MoonBit toolchain | `moon 0.1.20261104 (940aa18 2026-11-04)` |
| Host | Simular box `main`, Linux 6.8.0-142-generic, x86_64 |
| CPU | Intel Xeon Platinum 8581C @ 2.10 GHz, 4 vCPU |
| RAM | 8,099,556 kB total (~7.7 GiB) |
| Python | 3.12.3; numpy 2.5.4; qdrant-client 1.20.0 |
| MinIO | `2025-09-07T16:13:09Z`, commit `07c3a429…` (manual `mc admin info`) |
| Qdrant | 1.20.0, single node on `127.0.0.1:6333`, storage `/workspace/storage` |
| Concurrency | 1 in-flight query; load generator pinned to CPU 3 (`affinity=[3]`); servers unpinned |
| Turbofish workers | `SPND_WORKERS=4`, 64 MB worker cache each, 300 s TTL |

**Actual toxiproxy configuration** (captured from `/proxies` by the runner, not
assumed): proxy `minio`, `127.0.0.1:19000 → 127.0.0.1:9000`, one toxic:
**latency, downstream, 50 ms ±20 ms jitter**. There is **no bandwidth toxic**
configured. The direct endpoint is `http://127.0.0.1:9000` (local MinIO, no
proxy).

### Architecture change from the previous result

The previous run read namespace/segment metadata from S3 on every cold start:
422 `GetObject` requests for 20 queries, a 558 ms first query direct and a
23.1 s first query through toxiproxy. That was the wrong architecture for a
metadata-bearing service on the same VM.

This run adds `cmd/metad`, a small SSD-backed metadata service. `cmd/serve`
mirrors namespace / manifest / segment-meta / row-column / centroid /
tombstone / global-IVF-meta objects into it on write, and reads them from it on
cold start. Query data shards (segment vectors, FTS postings, global IVF vector
parts) remain in object storage and are fetched by the query process. Metadata
service requests are local HTTP, not S3, and are therefore not included in the
S3 counts below.

The metadata service is deliberately **not restarted** for the cold window: it
is a long-lived local service, like a catalog or a local SSD page cache. The
cold window restarts the query process, which is the thing whose cold-start
behaviour is being measured.

## 2. Dataset, queries and ground truth

| Parameter | Value |
| --- | --- |
| Docs | 50,000 |
| Dimensions | 128, float32, L2-normalised after generation |
| Generator | 32 random centres in `[-1,1]^128`, doc = centre + U(-0.20, 0.20)^128 |
| Query set | 560 unique docs + Gaussian noise σ=0.05 per dim, re-normalised |
| Seed | 20261115 |
| Measured queries | 400 per repetition × 3 repetitions (slices 0–400) |
| Tuning queries | 100 (slice 400–500) |
| Cold queries | 20 per restart × 3 restarts (slice 500–560) |
| Ground truth | **exact brute-force cosine top-10 over all 50k docs** (numpy `q @ docs.T`, no index) |
| Dataset hash | `205712278d9a7a0ffdcdcdbd2d822bc467a98b0f2ed4bbd85e6c66859817463c` |

Both engines received the same float32 ids/vectors and the same query vectors.
Attributes (`text`, `category`, `ts`, `public`) were written to both systems;
queries returned only `id`+`score` (`include_attributes: []` for Turbofish,
`with_payload=False` for Qdrant).

## 3. Iso-recall tuning

Tuning used the separate 100-query slice. Recall is exact overlap@10 with brute
force. Every grid point is listed; the chosen point is closest to recall 0.95
(ties prefer lower p50).

### Turbofish (IVF, `nlist=64`); same recall on both endpoints

| nprobe | recall@10 | direct p50 / p95 / p99 (ms) | toxiproxy p50 / p95 / p99 (ms) |
| ---: | ---: | ---: | ---: |
| 1 | 0.792 | 0.619 / 0.982 / 1.183 | 0.716 / 1.044 / 1.127 |
| **2** | **0.953** | **0.674 / 1.055 / 1.159** | **0.777 / 1.252 / 1.428** |
| 4 | 0.996 | 0.997 / 1.559 / 1.776 | 1.042 / 1.464 / 1.641 |
| 8 | 0.998 | 1.527 / 2.149 / 2.313 | 1.548 / 2.046 / 2.130 |
| 16 | 0.998 | 2.149 / 3.032 / 3.178 | 2.340 / 3.013 / 3.120 |
| 32 | 0.998 | 3.723 / 4.357 / 4.682 | 3.846 / 4.544 / 4.787 |
| 64 | 0.998 | 6.318 / 7.062 / 7.403 | 6.416 / 7.282 / 7.998 |

Turbofish index: IVF, `nlist=64` (server default for this build), f16 vector
storage, one global IVF base after `POST /compact`.

### Qdrant (HNSW, `m=16`, `ef_construct=100`, all 50k vectors indexed)

| hnsw_ef | recall@10 | p50 / p95 / p99 (ms) |
| ---: | ---: | ---: |
| 16 | 0.614 | 1.842 / 2.059 / 2.354 |
| 24 | 0.705 | 1.867 / 2.115 / 2.372 |
| 32 | 0.781 | 1.886 / 2.145 / 2.217 |
| 48 | 0.870 | 1.959 / 2.383 / 2.911 |
| 64 | 0.912 | 2.146 / 2.625 / 3.736 |
| **80** | **0.944** | **2.090 / 2.540 / 2.742** |
| 96 | 0.962 | 2.057 / 2.374 / 2.632 |
| 128 | 0.974 | 2.098 / 2.299 / 2.379 |
| 160 | 0.982 | 2.118 / 2.387 / 2.589 |
| 192 | 0.984 | 2.127 / 2.414 / 4.510 |
| 224 | 0.986 | 2.078 / 2.342 / 2.561 |
| 256 | 0.989 | 2.201 / 2.429 / 2.900 |
| 384 | 0.989 | 2.258 / 2.527 / 2.784 |

Collection was created with `indexing_threshold=1` (kB) and
`default_segment_number=1`; ingestion then waited until
`indexed_vectors_count == 50000` **and** status `green`
(`50000/50000`, 2 segments, `green`). `indexing_threshold=0` is *not* "index
everything": Qdrant documents it as disabling vector indexing, and a discarded
run confirmed recall 1.000 with plain scans. The server-default 10,000 kB
threshold left a ~9,000-vector segment brute-forced at this scale; that
configuration was also discarded.

### Chosen operating point

| Engine | Parameter | Tuning recall | Tuning p50 | Warm recall (400 q × 3) |
| --- | ---: | ---: | ---: | ---: |
| Turbofish direct | nprobe=2 | 0.953 | 0.674 ms | **0.9447** |
| Turbofish toxiproxy | nprobe=2 | 0.953 | 0.777 ms | **0.9447** |
| Qdrant | hnsw_ef=80 | 0.944 | 2.090 ms | **0.9467** |

The operating point is close but not exact: Qdrant's measured recall is
0.2 percentage points higher than Turbofish's. With 400 queries the binomial
standard error on each recall estimate is roughly 1.1 pp, so this difference is
far inside sampling noise; the comparison is "at approximately equal recall",
not a mathematically exact iso-recall pair.

## 4. Warm latency and throughput

Warm = 100 burn-in queries per engine, service still running, then 400 measured
queries. Three repetitions, engines interleaved and rotated each repetition.
Latency is one end-to-end query over a persistent HTTP/1.1 connection,
single-threaded, concurrency 1.

| Engine | rep | recall@10 | p50 ms | p95 ms | p99 ms | qps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Turbofish direct | 1 | 0.9447 | 0.681 | 1.177 | 1.404 | 1161.1 |
| | 2 | 0.9447 | 0.647 | 1.090 | 1.338 | 1231.6 |
| | 3 | 0.9447 | 0.652 | 1.096 | 1.274 | 1222.1 |
| | mean | 0.9447 | **0.660** | **1.121** | **1.338** | **1204.9** |
| Turbofish toxiproxy | 1 | 0.9447 | 0.709 | 1.196 | 1.597 | 1103.2 |
| | 2 | 0.9447 | 0.660 | 1.086 | 1.264 | 1198.4 |
| | 3 | 0.9447 | 0.673 | 1.101 | 1.383 | 1144.2 |
| | mean | 0.9447 | **0.681** | **1.128** | **1.415** | **1148.6** |
| Qdrant | 1 | 0.9467 | 2.001 | 2.300 | 3.106 | 452.3 |
| | 2 | 0.9467 | 2.009 | 2.305 | 2.465 | 483.0 |
| | 3 | 0.9467 | 2.017 | 2.282 | 2.589 | 483.0 |
| | mean | 0.9467 | **2.009** | **2.296** | **2.720** | **472.8** |

Means in this table are arithmetic means of the three per-repetition
statistics; percentiles are not pooled across repetitions (the JSON keeps each
repetition separately under `warm` and their spread under `warm_pooled`).

At this operating point the Turbofish p50 is ~3.0× lower than Qdrant's
(0.660 vs 2.009 ms) and serial throughput ~2.55× higher (1205 vs 473 qps), at
0.2 pp lower measured recall (inside sampling noise).

**Warm requests to MinIO were zero.** In the traced warm window (100 queries
after warm-up) both Turbofish endpoints issued **0 S3 requests** and read 0
bytes: the whole working set was resident in the 4×64 MB worker caches. The
direct and toxiproxy warm numbers are therefore nearly identical, and they say
nothing about object-storage latency; only the cold window does.

## 5. Ingest and indexing

Same batch size (1000 rows) for both engines. Turbofish: `POST /write` per
batch, health wait, then `POST /compact` and a second health wait. Qdrant:
`upsert(wait=True)` per batch, then wait for `green` with
`indexed_vectors_count == points_count`.

| Engine | write time | write docs/s | batch p50 / p95 (ms) | indexing/compaction | total write+index |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qdrant | 4.038 s | 12,383.0 | 62.33 / 93.15 | 14.067 s index wait | 18.105 s |
| Turbofish direct MinIO | 53.088 s | 941.8 | 688.47 / 2164.03 | 1.706 s compact | 54.794 s |
| Turbofish toxiproxy | 417.656 s | 119.7 | 4366.37 / 34044.46 | 23.063 s compact (+1.422 s health) | 442.141 s |

Turbofish's write times include the server's synchronous auto-compaction
(delta chain threshold 8); the final `POST /compact` is reported separately.
Qdrant's HNSW build happens after writes and is reported as index wait. These
are not identical work, so compare them as end-to-end ingest-to-searchable
costs, not as "index build throughput".

Turbofish's toxiproxy batch p95 of ~34 s is a direct consequence of the
per-write S3 request fan-out at 50 ms downstream latency; the direct MinIO path
does the same requests without that latency. The traced 1,000-doc ingest probe
issued 92 S3 requests (84 `PutObject`, 5 `GetObject`, 3 `ListObjectsV2`), and
took 0.91 s direct versus 5.76 s through toxiproxy.

## 6. Cold process (not cold object storage)

Each repetition restarts the query service and measures the first 20 queries
with no burn-in. "Restart" means the process; OS page caches, MinIO's caches,
toxiproxy buffers and the metadata service are **not** cleared. Qdrant is
restarted gracefully with the same binary/cwd/storage and all pre-existing
collections are verified present after restart; its collection is local
disk/mmap.

| Engine | rep | first query ms | p50 / p95 / p99 of 20 (ms) | recall@10 | process start→ready |
| --- | ---: | ---: | ---: | ---: | ---: |
| Turbofish direct | 1 | 39.6 | 7.42 / 14.91 / 34.64 | 0.945 | 0.103 s |
| | 2 | 38.5 | 7.20 / 14.52 / 33.74 | 0.960 | 0.104 s |
| | 3 | 36.9 | 6.13 / 21.55 / 33.85 | 0.955 | 0.102 s |
| | mean | **38.3** | 6.92 / 16.99 / 34.07 | 0.953 | |
| Turbofish toxiproxy | 1 | 175.2 | 120.60 / 155.98 / 171.39 | 0.945 | 0.103 s |
| | 2 | 173.3 | 132.32 / 156.75 / 170.01 | 0.960 | 0.104 s |
| | 3 | 191.3 | 137.93 / 157.71 / 191.24 | 0.955 | 0.104 s |
| | mean | **180.0** | 130.28 / 156.81 / 175.34 | 0.953 | |
| Qdrant | 1 | 11.5 | 4.87 / 7.88 / 10.40 | 0.955 | 0.41 s |
| | 2 | 11.9 | 4.54 / 8.50 / 11.28 | 0.950 | 0.41 s |
| | 3 | 14.1 | 4.82 / 7.89 / 12.92 | 0.940 | 0.41 s |
| | mean | **12.5** | 4.74 / 8.09 / 11.64 | 0.948 | |

The first query still dominates: the runner's separate cold trace measured
**31 S3 `GetObject` requests in the whole 20-query window** on both Turbofish
endpoints (1.55/query average, 7.44 MB of response bytes). These are data
shards; the metadata reads are local HTTP to `metad`. All 31 requests occurred
inside the first ~160 ms of the traced window, and the median of the remaining
queries is sub-millisecond because their probed parts are now resident.

That is the visible result of the architecture change. The previous run had
422 S3 GETs / 21.1 per query and a 23.1 s toxiproxy first query. This run has
31 S3 GETs / 1.55 per query, a 38 ms direct first query and a 180 ms toxiproxy
first query. The remaining gap to Qdrant's 12.5 ms is object-storage/data-shard
latency plus process startup, not metadata lookup.

Qdrant's `restart_seconds` (0.41 s) is only launch→`/readyz`; collection load
happens lazily and is captured by its first-query latency (11.5–14.1 ms).

## 7. Storage and memory

Storage snapshot taken after warm measurement, before the cold restarts, for
the new buckets/collection only. "Bytes" for Qdrant is **allocated disk bytes**
(`du -s -B1`); apparent size and sum-of-file-sizes are also in the JSON and are
much larger because Qdrant preallocates sparse mmap/WAL files.

| Store | bytes | objects | bytes/doc |
| --- | ---: | ---: | ---: |
| Turbofish + MinIO, direct ingest | 282,254,748 | 3,828 | 5,645.1 |
| Turbofish + MinIO, toxiproxy ingest | 310,113,227 | 3,830 | 6,202.3 |
| Qdrant collection | 72,011,776 | — | 1,440.2 |

For context only (not a correction of the measured numbers): the raw vector
payload is 12.8 MB at f16 (50k×128×2 B) or 25.6 MB at f32. Turbofish stores f16
vectors plus FTS/attribute columns; Qdrant stores f32 vectors plus payload.

**Post-run storage (same command, after cold window):** direct
283,202,189 B / 3,910 objects, toxiproxy 311,060,668 B / 3,912 objects, Qdrant
72,007,680 B. The Turbofish buckets grew by ~0.95 MB and 82 objects *after* the
snapshot because background merge-tree compaction continued to write new part
objects while the cold windows ran. This is real billed object storage, not a
measurement artifact.

Retained merge-tree base parts are the main reason the Turbofish bucket is
larger than the vector payload. Superseded compaction outputs are not
garbage-collected in object storage here, so 5.6 KB/doc is **not** the logical
vector/index size; it is the cumulative object bytes of this write/compaction
history. This run did not capture a per-prefix breakdown, so the split between
parts and segment/index objects is not asserted here. A fair "steady-state"
storage claim would need a retention/GC policy that this version does not apply
automatically. Qdrant's 72 MB conversely includes payload storage and sparse
preallocation, so neither side is a pure vector-byte comparison.

**RSS** (`VmRSS` / peak `VmHWM` from `/proc/<pid>/status`, measured after warm):

| Process | VmRSS | VmHWM |
| --- | ---: | ---: |
| Turbofish direct server | 48,196 kB | 48,196 kB |
| Turbofish toxiproxy server | 46,736 kB | 47,060 kB |
| Qdrant | 206,380 kB | 339,916 kB |
| MinIO | 374,828 kB | 415,632 kB |

Qdrant's RSS includes the unrelated pre-existing `bench_100k` collection
(121 MB on disk) because the service is shared; it is not attributable solely
to the benchmark collection. The two Turbofish server processes are separate
and each had its own 4×64 MB worker-cache budget.

## 8. S3 request counts

Counted from real `mc admin trace --json local` events filtered to the run's
bucket, never packet captures. Tracing windows are separate from the latency
measurements because tracing adds overhead. These counts are S3 only; local
metadata-service HTTP requests are not in this table.

| Window | Queries/docs | S3 requests | Requests/query | By API |
| --- | ---: | ---: | ---: | --- |
| Warm direct | 100 queries | 0 | 0.0 | — |
| Warm toxiproxy | 100 queries | 0 | 0.0 | — |
| Cold direct | 20 queries | 31 | 1.55 | GetObject ×31 |
| Cold toxiproxy | 20 queries | 31 | 1.55 | GetObject ×31 |
| Ingest probe (1,000 docs, one write) | 1,000 docs | 92 | 0.092/docs | GetObject ×5, PutObject ×84, ListObjectsV2 ×3 |

The 0-request warm result is the expected consequence of a fully cache-resident
working set; it is reported rather than hidden. The cold window's 31 requests
are all data shards fetched while the restarted process repopulates its worker
caches.

## 9. What this run shows, and what it does not

What it shows:

* Moving metadata to a long-lived local SSD service removes the cold-start
  metadata fan-out: 422 S3 GETs → 31, 558 ms → 38 ms direct first query,
  23.1 s → 180 ms through 50 ms ±20 ms toxiproxy.
* At approximately equal recall (~0.945), warm Turbofish queries were ~3.0×
  faster at p50 and ~2.55× higher serial throughput than Qdrant on this VM.
* When Turbofish's working set is cache-resident, the MinIO/toxiproxy path
  disappears from query latency (0 S3 GETs; direct ≈ toxiproxy).
* Qdrant still wins the cold-process window (12.5 ms vs 38.3 ms direct and
  180.0 ms toxiproxy) because it serves from local disk/mmap and has no
  object-storage hop.
* Ingest through toxiproxy is ~7.9× slower than direct MinIO by write
  throughput (119.7 vs 941.8 docs/s; ~8.1× end-to-end including compaction)
  and ~24× slower than Qdrant's write+index path here, driven by the S3 request
  fan-out per 1000-row write and 50 ms per-response latency.
* The Turbofish bucket is ~3.9–4.3× Qdrant's allocated bytes for this dataset,
  mostly because of retained merge-tree base parts.

What it does not show:

* It is not a hybrid/BM25 comparison. Qdrant has no BM25 here; only vector
  queries were measured.
* It is not "object storage is faster than local disk" or vice versa. Warm
  Turbofish was effectively in-memory; cold Turbofish paid object-storage
  latency. The honest statement is that warm CPU-side search was fast and the
  cold data-shard path still costs tens to hundreds of milliseconds.
* It is not a statement about steady-state Turbofish storage size without a
  compaction/GC policy; the bucket contains retained compacted generations.
* It is not a concurrency or saturation benchmark: concurrency was 1 and the
  client was pinned to one CPU.

## 10. Run history and discarded configurations

Earlier 50k runs validated the harness and are summarized for transparency, not
as evidence:

* **Run 2** used Qdrant's default optimiser settings. It indexed 41,000/50,000
  vectors and left a 9,000-vector segment brute-forced. Warm: Turbofish
  0.72 ms p50 / recall 0.9447; Qdrant 2.80 ms / recall 0.9413. Ingest:
  Turbofish direct 739 docs/s, toxiproxy 77.6 docs/s. Storage: 282.3/310.1 MB
  vs Qdrant 71.5 MB. Its Qdrant cold window had only one successful restart
  because of a harness bug (an unreaped Qdrant child looked alive); that bug
  was fixed before the next run.
* **Run 3** set `indexing_threshold=0`, which Qdrant defines as *disabling*
  vector indexing. It reported recall 1.000 and ~3.9 ms p50 for Qdrant because
  the collection was fully scanned; it is not an iso-recall comparison and was
  discarded.
* **Run 4** (the previous reported run) used `indexing_threshold=1` +
  `default_segment_number=1`, but still read metadata from S3. Its cold window
  was the 422-GET / 23.1 s result that motivated `cmd/metad`.
* **Run 5** (reported here) keeps the same Qdrant configuration and adds the
  local metadata service.

Warm Turbofish results are stable across these runs (p50 0.65–0.78 ms at
nprobe=2), which is reassuring; Qdrant numbers moved with its index
configuration, as expected.

## 11. Remaining uncertainties / threats to validity

1. **One dataset shape and scale.** 50k × 128 clustered vectors at recall
   ~0.95. Uniform random vectors, higher dimensions, filters, 1M docs or a
   different `nlist`/`nprobe` ratio can change the ranking of engines.
2. **Warm caches hide storage cost.** The 50k working set fits in Turbofish's
   4×64 MB worker caches. A larger dataset would produce warm S3 reads and
   different warm latency. No cache-size sweep was done.
3. **Cold is cold-process, not cold-storage.** OS page cache, MinIO's caches
   and the metadata service were warm; dropping caches needs root and would
   disturb other tenants. The cold numbers are a lower bound for a truly cold
   object store and are not directly comparable to Qdrant's local-disk cold
   start.
4. **Storage/media asymmetry.** Qdrant uses local disk/mmap; Turbofish uses
   MinIO over a 50 ms ±20 ms proxy (no bandwidth limit). This is the intended
   contrast, but it means "latency" results are not same-medium.
5. **Client overhead is included.** Qdrant is queried over its HTTP JSON API
   via qdrant-client; Turbofish over HTTP JSON with `http.client`. A gRPC
   Qdrant client or a lower-overhead client could lower Qdrant's ~2 ms p50.
   Both clients ran on the same client CPU.
6. **Recall is approximate iso-recall.** Turbofish 0.9447 vs Qdrant 0.9467.
   The 0.2 pp gap is far inside the ~1.1 pp sampling error of 400 queries.
   Qdrant's recall at a fixed `ef` also depends on the index build/configuration.
   Exact recall equivalence would need repeated builds and/or interpolation
   between `ef` points.
7. **Qdrant is a shared service.** Restarting it reloads `bench_100k`
   (121 MB) and other collections; Qdrant cold numbers include unrelated work,
   and its RSS includes those collections.
8. **Indexing work is different.** Qdrant builds HNSW after writes (14.1 s
   wait here); Turbofish compacts inside the write path and with a final
   `POST /compact` (1.7 s direct, 23.1 s toxiproxy). Ingest numbers are
   end-to-end costs, not equal units of index work.
9. **Storage snapshot timing.** Turbofish background compaction kept writing
   after the snapshot (+0.95 MB / +82 objects during cold). The reported
   storage bytes are for the defined snapshot; post-run values are also given.
10. **Tail noise.** p99 has few samples and occasional outliers. Medians and
    the per-rep spread are more stable than single p99 digits.
11. **No concurrency sweep, no filters, no hybrid, one VM.** Serial throughput
    is not a saturation number, and hybrid/BM25 behavior is out of scope.
12. **Metadata service durability is out of scope.** `metad` is a local
    SSD-backed cache/service populated on write; S3 remains the durable source
    of truth. Losing the metadata directory degrades to S3 reads, not data
    loss. Multi-node sharing/failover was not tested.

## 12. Reproduce

Inside the benchmark VM:

```bash
export PATH="$HOME/.moon/bin:$PATH"
bash ~/turbofish-perf/perf/box_bootstrap.sh          # pinned clone + release builds
cd ~/turbofish-perf
python3 perf/run_compare.py \
  --docs 50000 --dim 128 --queries 400 --reps 3 \
  --batch-size 1000 --target-recall 0.95 --keep-data
```

The exact invocation for this result was:

```bash
cd ~/turbofish-perf
python3 perf/run_compare.py --docs 50000 --queries 400 --reps 3 --keep-data
```

`run_compare.py` starts `cmd/metad` automatically on `127.0.0.1:8090` with a
run-specific `SPND_META_DIR`, and passes `SPND_META_URL` plus a per-bucket
`SPND_META_PREFIX` to both Turbofish servers. The metadata service stays up for
the cold window. Use `--metad-url` to reuse an already-running service, or
`--metad-bin` to point at a different binary.

All other values were defaults documented in `perf/README.md`. The JSON path is
`perf/results/compare-20261115T101916Z-33642.json`; the harness printed
`"errors": []`. Manual commands used for the supplementary numbers:

```bash
/home/user/.moon/bin/moon version
/opt/minio/mc admin info local --json
/opt/minio/mc du --json local/<bucket>
/opt/minio/mc ls --recursive --json local/<bucket>
du -s -B1 /workspace/storage/collections/<collection>
```

All buckets (`perf-w2-*`) and the Qdrant collection created for this run were
removed after the measurements; the pre-existing `seekpond` bucket and
`bench_100k` collection were left untouched.
