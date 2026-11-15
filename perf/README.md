# Turbofish vs Qdrant: a reproducible vector-search comparison

This directory contains a deliberately conservative comparison between
Turbofish and Qdrant for **vector-only** nearest-neighbour search. It exists
because earlier comparisons in this repository mixed otherwise incomparable
setups (different datasets/queries, index-reported recall, one-shot HTTP
connections, unmatched recall, hidden caches, hard-coded storage sizes).

Scope and non-claims:

* **Vector-only.** Qdrant has no BM25 equivalent here, so no hybrid / BM25
  parity is measured or claimed. Turbofish's FTS columns are written and stored
  because that is how the server stores rows, but queries are vector queries.
* **Different storage classes.** Turbofish reads its index from MinIO over the
  network (optionally through toxiproxy); Qdrant memory-maps local disk. The
  direct-MinIO and toxiproxy runs make that difference visible instead of
  hiding it. They are not "same storage" comparisons.
* Results are environment-specific. `perf/RESULTS.md` records what was actually
  measured by one run, including the exact VM, binary and config.

## Files

| File | Purpose |
| --- | --- |
| `run_compare.py` | End-to-end runner: dataset, exact ground truth, ingest, iso-recall tuning, warm/cold measurement, RSS/storage/request counts, JSON output. |
| `clients.py` | Persistent-connection clients: `http.client` keep-alive for Turbofish, `qdrant_client` for Qdrant; per-query timing. |
| `box_bootstrap.sh` | Run **inside** the Linux VM: clone the pinned commit and build `cmd/serve` in release mode. |
| `run_on_box.sh` | Laptop helper: upload only `perf/` into the VM and run the comparison there. |
| `results/*.json` | Machine-readable output of real runs (written inside the VM). |

The harness never edits the Turbofish source tree. The measurement build is a
fresh clone inside the VM, checked out at the commit recorded in the JSON.

## Dataset and ground truth

`build_dataset()` generates one deterministic dataset from a seed:

* `docs` clustered vectors: `clusters` random centres in `[-1, 1]^dim`, each doc
  is its centre plus uniform noise in `[-noise, noise]^dim`, then L2-normalised.
* queries are distinct docs plus small Gaussian noise (`qnoise`), then
  L2-normalised.
* text/category/ts/public attributes are deterministic functions of the doc id
  and are written to both systems, so stored attributes are comparable.

The same float32 arrays (same ids, same vectors, same query vectors) are sent
to both engines. `dataset_sha256` hashes the exact doc vectors, query vectors
and ids.

**Ground truth is exact brute-force cosine top-10 over all docs**, computed with
numpy (`queries @ docs.T`, chunked) with ties broken by ascending id. No engine
result is ever used as ground truth. Recall@10 is the mean id-overlap between
ground truth and each engine's top-10.

## Ingest protocol

* Same row batch size for both engines: default `1000`.
* Turbofish: `POST /write` per batch, then `GET /health` until `num_docs`
  reaches N, then `POST /compact` (the engine's global IVF compaction) and a
  second health wait. Reported separately: write time, health wait, compaction.
* Qdrant: `upsert(..., wait=True)` per batch, then poll until the collection
  status is `green` (all optimisers/HNSW builds finished). Reported separately:
  write time, index wait. The collection is created with
  `optimizers_config.indexing_threshold = 1` (kB; Qdrant's semantics: *maximum*
  plain-index size, and `0` disables vector indexing) and
  `default_segment_number = 1`, then the runner waits until
  `indexed_vectors_count == points_count` **and** status is `green`. This is
  deliberate: the server-default 10,000 kB threshold (observed in the run-2
  collection config) left a ~4.6 MB / 9,000-vector segment brute-forced at 50k
  docs, and `indexing_threshold = 0` disabled HNSW entirely (recall 1.000 with
  ~4 ms queries). All HNSW parameters remain at their defaults (`m=16`,
  `ef_construct=100`).
* Turbofish is ingested twice, once through direct MinIO and once through
  toxiproxy, into two separate new buckets, so ingest throughput is measured
  under each storage path.
* Ingest request counts are sampled separately with `mc admin trace` (see
  below) into a throwaway namespace; that traced ingest is not used for timing.

## Iso-recall protocol

1. Both engines are warmed with `--burnin` queries (default 100).
2. A separate tuning query slice is replayed over a parameter grid:
   * Turbofish `nprobe` in `1,2,4,8,16,32,64`
   * Qdrant `hnsw_ef` in `16,24,32,48,64,80,96,128,160,192,224,256,384`
3. For every grid point the runner reports recall@10 and latency.
4. The point whose recall is closest to `--target-recall` (default 0.95) is
   chosen. Ties prefer lower p50. The chosen point's actual recall is reported
   again in every warm and cold repetition. There is no interpolation and no
   hidden parameter: all grid points are in the JSON.

## Warm and cold definitions

* **Warm**: after 100 burn-in queries per engine, with the service process kept
  running. Worker caches, metadata caches, Qdrant's loaded HNSW and the OS page
  cache are warm. The measured sequence is 400 queries per repetition.
* **Cold (cold process, not cold object storage)**: the service process is
  restarted and the first 20 queries are measured without burn-in. The OS page
  cache is **not** dropped and MinIO itself is not restarted.
  * Turbofish: new server process, empty worker/metadata caches; it must fetch
    objects from MinIO over the network.
  * Qdrant: the shared Qdrant service is gracefully restarted (same binary, same
    storage directory) and the collection is loaded lazily on the first query.
    Qdrant serves from local disk / mmap, so this is not comparable to a cold
    network object store. The restart is guarded: the collection list is checked
    before and after, and the collection is never deleted or modified.
  * A first query after restart is **not** called "cold S3" in any result.

Cold latency is reported as `first_query_ms` plus p50/p95 over the 20-query
window, per repetition.

## Repetitions, interleaving, CPU

* At least 3 warm repetitions by default, engines interleaved and rotated each
  repetition (`tf_direct → tf_toxi → qdrant`, then rotated) to spread drift.
* Concurrency is 1 (one in-flight query). The load-generator process is pinned
  with `taskset` to one CPU (default CPU 3) when available; servers are not
  pinned and share the remaining cores with MinIO, toxiproxy and Qdrant. The
  JSON records the client affinity and `nproc`.
* All latency includes client-side JSON encode/decode for exactly one request.
  Connections are kept alive (HTTP/1.1); a reconnect is only attempted if the
  server closed an idle connection, and the retry is timed from the fresh
  request.

## Storage, memory and request counts

* Turbofish/MinIO storage: `mc du --json local/<bucket>` (real object bytes and
  object count for the new bucket only).
* Qdrant storage: allocated disk bytes of
  `<qdrant-storage>/collections/<collection>` via `du -s -B1`, plus apparent
  bytes and the sum of file sizes. Sparse WAL/mmap files make apparent size
  much larger than allocated size; both are in the JSON.
* RSS: `/proc/<pid>/status` `VmRSS` and high-water `VmHWM` for both Turbofish
  servers, Qdrant and MinIO.
* S3 requests: real `mc admin trace --json local` event counts, filtered to the
  run's bucket. No packet captures and no `sudo tcpdump`. Tracing is run in a
  separate window because it adds overhead; it is excluded from latency stats.
  Warm request counts can legitimately be 0 when everything is cached.
  Post-restart cold counts and ingest request counts are measured separately.

## Reproduction

Inside the VM (4 vCPU x86_64, MinIO on `127.0.0.1:9000`, toxiproxy on
`127.0.0.1:19000`, Qdrant on `127.0.0.1:6333`):

```bash
export PATH="$HOME/.moon/bin:$PATH"
bash ~/turbofish-perf/perf/box_bootstrap.sh          # pinned clone + release build
cd ~/turbofish-perf
python3 perf/run_compare.py --smoke                  # functional smoke test
python3 perf/run_compare.py \
  --docs 50000 --dim 128 --queries 400 --reps 3 \
  --batch-size 1000 --target-recall 0.95 \
  --keep-data
```

From the laptop:

```bash
bash perf/run_on_box.sh --smoke
bash perf/run_on_box.sh --docs 50000 --queries 400 --reps 3 --keep-data
```

Notes:

* The runner discovers MinIO credentials from `~/.mc/config.json` (alias
  `local`) and passes them to the server through its environment; it never
  prints keys or secrets.
* New MinIO buckets are named `perf-w2-direct-<run>` / `perf-w2-toxi-<run>` and
  the Qdrant collection `perf_w2_<run>`; no existing data is touched. Cleanup
  runs at the end unless `--keep-data` is passed, and only ever deletes names
  with those prefixes.
* Turbofish ports are `8081`/`8082` so an existing server on `8080` is not
  disturbed.
* Qdrant restarts for the cold window keep the same binary, cwd and storage
  directory, and verify that all pre-existing collections are still present.
  Use `--no-qdrant-restart` to skip them.
* The actual toxiproxy configuration is captured from
  `http://127.0.0.1:8474/proxies` into `environment.toxiproxy_config`. Do not
  assume a latency or bandwidth value from documentation: report what the proxy
  is actually configured with.
* `--smoke` shrinks the dataset below Qdrant's full-scan threshold, so Qdrant
  answers by plain scan and its recall/latency are only a functional check, not
  meaningful benchmark numbers.

## Metrics in the JSON

Top-level keys: `environment`, `config`, `dataset`, `ingest`, `recall_tuning`,
`chosen_params`, `warm`, `warm_pooled`, `cold`, `rss`, `storage`, `s3_requests`,
`summary`, `errors`.

Latency stats are per-request seconds converted to milliseconds:
`p50_ms`, `p95_ms`, `p99_ms`, `mean_ms`, `std_ms`, `min_ms`, `max_ms`, plus
`wall_seconds` and `qps` for the sequence. Repetition aggregates report the
per-rep values and their mean/min/max, so spread is visible; no percentiles are
pooled across repetitions.

## Threats to validity

1. **Storage is not the same class.** Qdrant reads local disk/mmap; Turbofish
   reads MinIO over HTTP (with 50 ms ±20 ms downstream latency through the
   toxiproxy proxy configured in this VM, and no bandwidth toxic enabled at the
   time of the run — see the captured proxy config). Warm Turbofish queries can
   be fully cache-resident and then do zero S3 GETs; the cold window and the
   direct/toxiproxy difference expose the storage path.
2. **Vector encoding differs.** Turbofish stores f16 vectors by default; Qdrant
   stores f32. This affects both storage bytes and score rounding. Storage
   numbers are reported as measured, not normalised.
3. **OS caches are not dropped.** "Cold" means cold process, not cold storage.
   MinIO's own caches, the OS page cache, toxiproxy buffers and Qdrant's mmap
   are warm. A single `echo 3 > drop_caches` would need root and would disturb
   other tenants, so it is intentionally not done.
4. **Single client, loopback network.** Concurrency 1 measures per-query latency
   and serial throughput, not saturating throughput under load. Loopback and
   a shared 4-vCPU VM mean CPU contention with MinIO/toxiproxy/Qdrant; the
   interleaved repetitions reduce, but do not eliminate, drift.
5. **Qdrant is a shared service.** The cold window restarts it. Its startup
   loads existing collections too (including unrelated ones), so restart time
   is not purely attributable to this benchmark collection.
6. **Indexing is asynchronous in Qdrant** (optimisers/HNSW) and partly
   synchronous in Turbofish (compaction inside the write path). Ingest numbers
   are split into write vs index/compaction, but they are not identical work.
7. **Turbofish object storage may retain old versions/garbage** after
   compactions, since S3 does not have in-place deletion of superseded objects
   in this engine. `mc du` therefore measures actual billed objects including
   any such residue, not the minimal logical index size.
8. **Exact ground truth is float32 over the generated vectors.** Both engines
   see the same rows, but Turbofish's f16 storage and IVF approximation can
   change near-ties. Ties are broken by id in ground truth; recall counts id
   overlap, not score equality.
9. **Recall is tuned on a separate 100-query slice**, then measured on the
   remaining queries, so the reported warm recall is not the tuning number.
   With limited queries, recall estimates have sampling noise.
10. **`mc admin trace` adds overhead** and is excluded from latency windows.
    Warm counts of 0 mean "served from cache", not "no requests were measured".
11. **Client-side serialization is inside the latency.** Turbofish rows are
    JSON; Qdrant uses its own JSON/protobuf transport. The numbers reflect
    end-to-end single-request latency for these clients.
12. **This is not a claim about Turbofish's hybrid/BM25 performance.** Only
    vector queries are compared.
