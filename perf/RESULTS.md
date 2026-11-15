# Results: Turbofish (MinIO) vs Qdrant (local disk), vector-only

This file reports one real run of `perf/run_compare.py`. All numbers below are
read from
[`results/compare-20261115T093654Z-31288.json`](results/compare-20261115T093654Z-31288.json),
which has `"errors": []`. Nothing here is hard-coded or estimated. Manual
supplementary measurements are marked as such and their commands are given.

Run window: **2026-11-15T09:36:54Z → 2026-11-15T09:52:41Z** (15m47s wall).
The JSON's `started_at` / `finished_at` and per-phase values are authoritative;
the wall time includes dataset generation, both Turbofish ingests, tuning,
warm/cold measurement and storage capture.

## 1. Provenance and environment

| Item | Value |
| --- | --- |
| Turbofish commit | `3911395f96574a8d370b9cd030275b42461a6884` (pinned clone in the VM) |
| Turbofish binary | `_build/native/release/build/cmd/serve/serve.exe` |
| Binary SHA-256 | `81c3e5792413dd34a0475acfe002cc58433748a13ffab746aed16ce8972269bb` |
| Binary build time | 2026-11-15T08:16:16Z |
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
configured. Earlier descriptions of this environment mentioned 30 ms ±10 ms and
100 MB/s; those were not the live configuration, so all "toxiproxy" numbers
here are for 50 ms ±20 ms with unlimited bandwidth.

The direct endpoint is `http://127.0.0.1:9000` (local MinIO, no proxy).

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
| 1 | 0.792 | 0.694 / 1.059 / 1.194 | 0.675 / 0.894 / 1.000 |
| **2** | **0.953** | **0.722 / 1.128 / 1.693** | **0.742 / 1.127 / 1.193** |
| 4 | 0.996 | 0.998 / 1.444 / 1.574 | 1.062 / 1.481 / 1.903 |
| 8 | 0.998 | 1.427 / 1.930 / 2.063 | 1.568 / 2.007 / 2.182 |
| 16 | 0.998 | 2.456 / 3.583 / 4.716 | 2.372 / 3.029 / 3.660 |
| 32 | 0.998 | 3.835 / 4.627 / 4.829 | 4.015 / 4.824 / 5.167 |
| 64 | 0.998 | 6.537 / 7.321 / 7.791 | 7.120 / 7.684 / 8.491 |

Turbofish index: IVF, `nlist=64` (server default for this build), f16 vector
storage, one global IVF base after `POST /compact`.

### Qdrant (HNSW, `m=16`, `ef_construct=100`, all 50k vectors indexed)

| hnsw_ef | recall@10 | p50 / p95 / p99 (ms) |
| ---: | ---: | ---: |
| 16 | 0.589 | 1.958 / 2.271 / 3.461 |
| 24 | 0.706 | 1.996 / 2.427 / 2.586 |
| 32 | 0.796 | 2.025 / 2.274 / 2.492 |
| 48 | 0.886 | 2.074 / 2.328 / 2.405 |
| 64 | 0.934 | 2.102 / 2.362 / 2.489 |
| **80** | **0.960** | **2.197 / 2.589 / 2.727** |
| 96 | 0.971 | 2.150 / 2.730 / 2.989 |
| 128 | 0.986 | 2.256 / 2.563 / 2.694 |
| 160 | 0.992 | 2.269 / 2.664 / 2.800 |
| 192 | 0.995 | 2.286 / 2.499 / 2.515 |
| 224 | 0.997 | 2.328 / 2.657 / 2.799 |
| 256 | 0.999 | 2.292 / 2.684 / 2.873 |
| 384 | 0.999 | 2.376 / 2.783 / 2.920 |

Collection was created with `indexing_threshold=1` (kB) and
`default_segment_number=1`; ingestion then waited until
`indexed_vectors_count == 50000` **and** status `green`
(`50000/50000`, 2 segments, `green`). `indexing_threshold=0` is *not* "index
everything": Qdrant documents it as disabling vector indexing, and a discarded
run confirmed recall 1.000 with plain scans. The server-default 10,000 kB
threshold (the value recorded in the run-2 collection config) left a ~4.6 MB /
9,000-vector segment brute-forced at this scale; that configuration was also
discarded.

### Chosen operating point

| Engine | Parameter | Tuning recall | Tuning p50 | Warm recall (400 q × 3) |
| --- | ---: | ---: | ---: | ---: |
| Turbofish direct | nprobe=2 | 0.953 | 0.722 ms | **0.9447** |
| Turbofish toxiproxy | nprobe=2 | 0.953 | 0.742 ms | **0.9447** |
| Qdrant | hnsw_ef=80 | 0.960 | 2.197 ms | **0.9365** |

The operating point is close but not exact: Turbofish's measured recall is
0.82 percentage points higher than Qdrant's. With 400 queries the binomial
standard error on each recall estimate is roughly 1.1 pp, so this difference is
within sampling noise; the comparison is "at approximately equal recall",
not a mathematically exact iso-recall pair.

## 4. Warm latency and throughput

Warm = 100 burn-in queries per engine, service still running, then 400 measured
queries. Three repetitions, engines interleaved and rotated each repetition.
Latency is one end-to-end query over a persistent HTTP/1.1 connection,
single-threaded, concurrency 1.

| Engine | rep | recall@10 | p50 ms | p95 ms | p99 ms | qps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Turbofish direct | 1 | 0.9447 | 0.716 | 1.136 | 1.420 | 1102.3 |
| | 2 | 0.9447 | 0.729 | 1.147 | 1.339 | 1090.6 |
| | 3 | 0.9447 | 0.709 | 1.128 | 1.256 | 1136.3 |
| | mean | 0.9447 | **0.718** | **1.137** | **1.338** | **1109.7** |
| Turbofish toxiproxy | 1 | 0.9447 | 0.785 | 1.253 | 1.656 | 1006.5 |
| | 2 | 0.9447 | 0.735 | 1.147 | 1.306 | 1086.5 |
| | 3 | 0.9447 | 0.748 | 1.154 | 1.311 | 1071.7 |
| | mean | 0.9447 | **0.756** | **1.185** | **1.424** | **1054.9** |
| Qdrant | 1 | 0.9365 | 2.010 | 2.420 | 3.592 | 475.4 |
| | 2 | 0.9365 | 1.960 | 2.623 | 4.169 | 468.5 |
| | 3 | 0.9365 | 2.172 | 2.468 | 2.861 | 447.1 |
| | mean | 0.9365 | **2.047** | **2.504** | **3.541** | **463.7** |

Means in this table are arithmetic means of the three per-repetition
statistics; percentiles are not pooled across repetitions (the JSON keeps each
repetition separately under `warm` and their spread under `warm_pooled`).

At this operating point the Turbofish p50 is ~2.85× lower than Qdrant's
(0.718 vs 2.047 ms) and serial throughput ~2.39× higher (1110 vs 464 qps),
at 0.8 pp higher measured recall. p99 is noisier: Qdrant's per-repetition p99 ranged 2.9–4.2 ms,
while Turbofish's stayed at 1.3–1.4 ms (direct and toxiproxy).

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
| Qdrant | 3.180 s | 15,724.9 | 50.72 / 62.23 | 15.063 s index wait | 18.243 s |
| Turbofish direct MinIO | 55.789 s | 896.2 | 696.49 / 2659.51 | 1.847 s compact | 57.636 s |
| Turbofish toxiproxy | 659.822 s | 75.8 | 8938.87 / 42101.25 | 33.277 s compact (+2.918 s health) | 696.017 s |

Turbofish's write times include the server's synchronous auto-compaction
(delta chain threshold 8); the final `POST /compact` is reported separately.
Qdrant's HNSW build happens after writes and is reported as index wait. These
are not identical work, so compare them as end-to-end ingest-to-searchable
costs, not as "index build throughput".

Turbofish's toxiproxy batch p95 of ~42 s is a direct consequence of the
per-write S3 request fan-out at 50 ms downstream latency (a separate traced
1000-row write issued 172 S3 requests); the direct MinIO path does the same
requests without that latency.

## 6. Cold process (not cold object storage)

Each repetition restarts the service and measures the first 20 queries with no
burn-in. "Restart" means the process; OS page caches, MinIO's caches and
toxiproxy buffers are **not** cleared. Qdrant is restarted gracefully with the
same binary/cwd/storage and all pre-existing collections are verified present
after restart; its collection is local disk/mmap.

| Engine | rep | first query ms | p50 / p95 / p99 of 20 (ms) | recall@10 | process start→ready |
| --- | ---: | ---: | ---: | ---: | ---: |
| Turbofish direct | 1 | 575.2 | 0.90 / 30.05 / 466.19 | 0.945 | 0.104 s |
| | 2 | 535.7 | 0.73 / 27.97 / 434.14 | 0.960 | 0.104 s |
| | 3 | 562.7 | 0.82 / 29.34 / 456.01 | 0.955 | 0.104 s |
| | mean | **557.9** | 0.82 / 29.12 / 452.11 | 0.953 | |
| Turbofish toxiproxy | 1 | 22,945.4 | 0.96 / 1148.52 / 18586.04 | 0.945 | 0.104 s |
| | 2 | 23,211.9 | 0.87 / 1161.73 / 18801.83 | 0.960 | 0.104 s |
| | 3 | 23,199.5 | 0.92 / 1161.50 / 18791.92 | 0.955 | 0.104 s |
| | mean | **23,118.9** | 0.92 / 1157.25 / 18726.60 | 0.953 | |
| Qdrant | 1 | 17.2 | 5.39 / 8.83 / 15.49 | 0.910 | 0.41 s |
| | 2 | 15.0 | 5.81 / 19.54 / 88.61 | 0.945 | 0.41 s |
| | 3 | 11.8 | 4.91 / 9.02 / 11.21 | 0.905 | 0.41 s |
| | mean | **14.6** | 5.37 / 12.46 / 38.44 | 0.920 | |

The first query dominates the cold window. The runner's separate cold trace
measured **422 S3 `GetObject` requests for the 20 queries, i.e. 21.1
requests/query and 15.81 MB of response bytes** on both Turbofish endpoints.
At 50 ms ±20 ms per request, that is ~23 s for the first query through
toxiproxy versus ~0.56 s direct. The median of the remaining 19 queries is
sub-millisecond because the server's worker caches have been repopulated.

Qdrant's `restart_seconds` (0.41 s) is only launch→`/readyz`; collection load
happens lazily and is captured by its first-query latency (11.8–17.2 ms). The
Qdrant cold window also has a ~5 ms p50, higher than its warm 2.05 ms, because
the 20-query window overlaps lazy collection/index loading.

## 7. Storage and memory

Storage snapshot taken after warm measurement, before the cold restarts, for
the new buckets/collection only. "Bytes" for Qdrant is **allocated disk bytes**
(`du -s -B1`); apparent size and sum-of-file-sizes are also in the JSON and are
much larger because Qdrant preallocates sparse mmap/WAL files.

| Store | bytes | objects | bytes/doc |
| --- | ---: | ---: | ---: |
| Turbofish + MinIO, direct ingest | 282,259,370 | 3,828 | 5,645.2 |
| Turbofish + MinIO, toxiproxy ingest | 310,113,227 | 3,830 | 6,202.3 |
| Qdrant collection | 72,011,776 | — | 1,440.2 |

For context only (not a correction of the measured numbers): the raw vector
payload is 12.8 MB at f16 (50k×128×2 B) or 25.6 MB at f32. Turbofish stores f16
vectors plus FTS/attribute columns; Qdrant stores f32 vectors plus payload.

**Post-run storage (same command, after cold window):**
`mc du --json local/<bucket>` gives 283,206,811 B / 3,910 objects (direct) and
311,060,675 B / 3,912 objects (toxiproxy); Qdrant is 72,007,680 B. The
Turbofish buckets grew by ~0.95 MB and 82 objects *after* the snapshot because
background merge-tree compaction continued to write new part objects while the
cold windows ran. This is real billed object storage, not a measurement
artifact.

**Object breakdown of the direct bucket at post-run** (manual
`mc ls --recursive --json`, summed by prefix):

| Prefix | bytes | objects | share |
| --- | ---: | ---: | ---: |
| `perf/_parts/` (merge-tree base parts) | 210,148,695 | 63 | 74.2% |
| `perf/` other (segments, global IVF, manifests) | 72,686,816 | 3,766 | 25.7% |
| ingest-probe namespace (1,000 docs) | 371,300 | 81 | 0.1% |

63 retained merge-tree base parts account for almost three quarters of the
Turbofish bucket. Superseded compaction outputs are not garbage-collected in
object storage here, so 5.6 KB/doc is **not** the logical vector/index size; it
is the cumulative object bytes of this write/compaction history. A fair
"steady-state" storage claim would need a retention/GC policy that this
version does not apply automatically. Qdrant's 72 MB conversely includes
payload storage and sparse preallocation, so neither side is a pure vector-byte
comparison.

**RSS** (`VmRSS` / peak `VmHWM` from `/proc/<pid>/status`, measured after warm):

| Process | VmRSS | VmHWM |
| --- | ---: | ---: |
| Turbofish direct server | 47,520 kB | 47,520 kB |
| Turbofish toxiproxy server | 46,712 kB | 46,712 kB |
| Qdrant | 206,680 kB | 487,176 kB |
| MinIO | 371,836 kB | 395,724 kB |

Qdrant's RSS includes the unrelated pre-existing `bench_100k` collection
(121 MB on disk) because the service is shared; it is not attributable solely
to the benchmark collection. The two Turbofish server processes are separate
and each had its own 4×64 MB worker-cache budget.

## 8. S3 request counts

Counted from real `mc admin trace --json local` events filtered to the run's
bucket, never packet captures. Tracing windows are separate from the latency
measurements because tracing adds overhead.

| Window | Queries/docs | S3 requests | Requests/query | By API |
| --- | ---: | ---: | ---: | --- |
| Warm direct | 100 queries | 0 | 0.0 | — |
| Warm toxiproxy | 100 queries | 0 | 0.0 | — |
| Cold direct | 20 queries | 422 | 21.1 | GetObject ×422 |
| Cold toxiproxy | 20 queries | 422 | 21.1 | GetObject ×422 |
| Ingest probe (1,000 docs, one write) | 1,000 docs | 172 | 0.172/docs | GetObject ×85, PutObject ×84, ListObjectsV2 ×3 |

The 0-request warm result is the expected consequence of a fully cache-resident
working set; it is reported rather than hidden. The ingest probe's traced
elapsed time was 1.071 s direct versus 10.041 s toxiproxy for the same 172
requests (separate namespace, not the timed 50k ingest).

## 9. What this run shows, and what it does not

What it shows:

* At approximately equal recall (~0.94–0.95), warm Turbofish queries were
  ~2.7–2.9× faster at p50 and ~2.4× higher serial throughput than Qdrant on
  this VM. Turbofish's recall was slightly higher, not lower.
* When Turbofish's working set is cache-resident, the MinIO/toxiproxy path
  disappears from query latency (0 S3 GETs; direct ≈ toxiproxy).
* With empty process caches, the storage path dominates: 422 GETs over 50 ms
  latencies produced a 23.1 s first query through toxiproxy versus 0.56 s
  direct and 14.6 ms for local-disk Qdrant.
* Ingest through toxiproxy is ~11.8× slower than direct MinIO by write
  throughput (75.8 vs 896.2 docs/s; ~12.1× end-to-end including compaction)
  and ~38× slower than Qdrant's write+index path here, driven by the S3
  request fan-out per 1000-row write (172 traced requests) and 50 ms
  per-response latency.
* The Turbofish bucket is ~3.9–4.3× Qdrant's allocated bytes for this dataset,
  mostly because of retained merge-tree base parts (74% of the bucket).

What it does not show:

* It is not a hybrid/BM25 comparison. Qdrant has no BM25 here; only vector
  queries were measured.
* It is not "object storage is faster than local disk" or vice versa. Warm
  Turbofish was effectively in-memory; cold Turbofish was dominated by
  network/storage latency. The honest statement is that warm CPU-side search
  was fast and the cold storage path was expensive.
* It is not a statement about steady-state Turbofish storage size without a
  compaction/GC policy; the bucket contains retained compacted generations.
* It is not a concurrency or saturation benchmark: concurrency was 1 and the
  client was pinned to one CPU.

## 10. Run history and discarded configurations

Four full 50k runs were made while validating the harness; the reported file is
run 4. The earlier runs are summarized for transparency, not as evidence:

* **Run 2** used Qdrant's default optimiser settings. It indexed 41,000/50,000
  vectors and left a 9,000-vector segment brute-forced. Warm: Turbofish
  0.72 ms p50 / recall 0.9447; Qdrant 2.80 ms / recall 0.9413. Ingest:
  Turbofish direct 739 docs/s, toxiproxy 77.6 docs/s. Storage: 282.3/310.1 MB
  vs Qdrant 71.5 MB. Its Qdrant cold window had only one successful restart
  because of a harness bug (an unreaped Qdrant child looked alive); that bug
  was fixed before run 4.
* **Run 3** set `indexing_threshold=0`, which Qdrant defines as *disabling*
  vector indexing. It reported recall 1.000 and ~3.9 ms p50 for Qdrant because
  the collection was fully scanned; it is not an iso-recall comparison and was
  discarded.
* **Run 4** (reported here) uses `indexing_threshold=1` +
  `default_segment_number=1` and waits for all 50,000 vectors to be HNSW
  indexed.

Warm Turbofish results are stable across these runs (p50 0.66–0.78 ms at
nprobe=2), which is reassuring; Qdrant numbers moved with its index
configuration, as expected.

## 11. Remaining uncertainties / threats to validity

1. **One dataset shape and scale.** 50k × 128 clustered vectors at recall
   ~0.95. Uniform random vectors, higher dimensions, filters, 1M docs or a
   different `nlist`/`nprobe` ratio can change the ranking of engines.
2. **Warm caches hide storage cost.** The 50k working set fits in Turbofish's
   4×64 MB worker caches. A larger dataset would produce warm S3 reads and
   different warm latency. No cache-size sweep was done.
3. **Cold is cold-process, not cold-storage.** OS page cache and MinIO's caches
   were warm; dropping caches needs root and would disturb other tenants. The
   cold numbers are a lower bound for a truly cold object store and are not
   directly comparable to Qdrant's local-disk cold start.
4. **Storage/media asymmetry.** Qdrant uses local disk/mmap; Turbofish uses
   MinIO over a 50 ms ±20 ms proxy (no bandwidth limit). This is the intended
   contrast, but it means "latency" results are not same-medium.
5. **Client overhead is included.** Qdrant is queried over its HTTP JSON API
   via qdrant-client; Turbofish over HTTP JSON with `http.client`. A gRPC
   Qdrant client or a lower-overhead client could lower Qdrant's ~2 ms p50.
   Both clients ran on the same client CPU.
6. **Recall is approximate iso-recall.** Turbofish 0.9447 vs Qdrant 0.9365.
   The 0.8 pp gap is within the ~1.1 pp sampling error of 400 queries.
   Qdrant's recall at a fixed `ef` also depends on the index build/configuration:
   `ef=64` gave tuning recall 0.932 in run 2 (41k vectors indexed, 9k
   brute-forced) and 0.934 in the final run (all 50k HNSW-indexed). Exact
   recall equivalence would need repeated builds and/or interpolation between
   `ef` points.
7. **Qdrant is a shared service.** Restarting it reloads `bench_100k`
   (121 MB) and other collections; Qdrant cold numbers include unrelated work,
   and its RSS includes those collections.
8. **Indexing work is different.** Qdrant builds HNSW after writes (15.1 s
   wait here); Turbofish compacts inside the write path and with a final
   `POST /compact` (1.8 s direct, 33.3 s toxiproxy). Ingest numbers are
   end-to-end costs, not equal units of index work.
9. **Storage snapshot timing.** Turbofish background compaction kept writing
   after the snapshot (+0.95 MB / +82 objects during cold). The reported
   storage bytes are for the defined snapshot; post-run values are also given.
10. **Tail noise.** p99 has few samples and occasional outliers (Qdrant's
    per-rep warm p99 ranged 2.9–4.2 ms here). Medians and the per-rep spread
    are more stable than single p99 digits.
11. **No concurrency sweep, no filters, no hybrid, one VM.** Serial throughput
    is not a saturation number, and hybrid/BM25 behavior is out of scope.

## 12. Reproduce

Inside the benchmark VM:

```bash
export PATH="$HOME/.moon/bin:$PATH"
bash ~/turbofish-perf/perf/box_bootstrap.sh          # pinned clone + release build
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

All other values were defaults documented in `perf/README.md`. The JSON path is
`perf/results/compare-20261115T093654Z-31288.json`; the harness printed
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
