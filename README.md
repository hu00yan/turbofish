# Turbofish

Object-storage-native hybrid search: BM25 full-text, IVF vector search, and
metadata filtering over immutable segments. The reference implementation is
written in MoonBit, with a small HTTP server and Python/TypeScript clients.

This is a research/reference codebase, not a production service. The design
keeps object storage as the durable source of truth and treats local memory and
NVMe as caches. Segments and manifests are immutable; a head pointer selects
the current manifest snapshot.

## Layout

| Path | Contents |
| --- | --- |
| `core/` | Errors, binary readers, f16, tokenizers (including CJK), vector math, IDs |
| `format/` | Column, posting list, vector, quantization, manifest, and tombstone codecs |
| `store/` | `ObjectStore` trait, in-memory store, batching, I/O budgets |
| `build/` | Segment construction, k-means, ingest, compaction, global IVF partitions |
| `query/` | BM25, IVF vector search, filters, hybrid RRF, metadata cache |
| `mtree/` | MergeTree-style parts, write-back buffer, compaction, CAS coordinators |
| `control/` | Catalog, leases, scatter-gather, worker coordination |
| `simstore/` | Deterministic object-store simulator with latency and request billing |
| `fsstore/`, `s3store/`, `s3http/` | Local filesystem and S3-compatible backends |
| `cmd/serve/` | HTTP API server |
| `cmd/main/`, `cmd/bench1m/` | End-to-end and large-scale benchmarks |
| `cmd/simcompare/`, `cmd/delta_bench/` | Storage-tier and write-amplification comparisons |
| `cmd/idxrepo/` | Index a source tree and run BM25/vector queries |
| `spec/` | Runtime-checked state-machine specifications |
| `sdk/` | Python and TypeScript clients |
| `docs/` | Architecture, deployment, control-plane, state-machine, and verification notes |
| `perf/` | Reproducible iso-recall comparison against Qdrant on a real VM |

## Build and test

```bash
moon check
moon test
moon build --target native --release cmd/serve
```

Run the local server with the filesystem backend:

```bash
SPND_STORE=fs:/tmp/turbofish-data SPND_PORT=8080 \
  ./_build/native/release/build/cmd/serve/serve.exe
```

For S3, MinIO, Cloudflare R2, Docker, and Kubernetes examples, see
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## API quickstart

```bash
curl -s -X POST localhost:8080/v1/namespaces/demo/create \
  -H 'content-type: application/json' \
  -d '{"fts_tokenizer":"word","distance_metric":"cosine"}'

curl -s -X POST localhost:8080/v1/namespaces/demo/write \
  -H 'content-type: application/json' \
  -d '{"rows":[{"id":1,"text":"object storage search","vector":[0.1,0.2],"category":"tech","ts":1700000000,"public":true}]}'

curl -s -X POST localhost:8080/v1/namespaces/demo/query \
  -H 'content-type: application/json' \
  -d '{"text":"storage","top_k":10}'
```

The clients in `sdk/python` and `sdk/typescript` wrap the same endpoints.

## Benchmarks

Benchmarks in this repository are internal comparisons, not a claim of
superiority over managed search services. They use synthetic data and a
deterministic storage simulator by default. In particular:

- `cmd/main` runs correctness gates, cost accounting, and latency loops on a
  small in-memory dataset.
- `cmd/bench1m` supports larger synthetic builds; set `BENCH_EXACT_GT=1` when
  reporting recall so the ground truth is a brute-force scan rather than the
  index's own result.
- `cmd/simcompare` reports simulated cold/warm tiers. Its latency is a model,
  not a wall-clock S3 measurement.
- `cmd/idxrepo` runs against a real source tree with deterministic hash
  embeddings; it validates mechanics, not embedding quality.
- `cmd/s3probe` exercises a real S3-compatible endpoint and counts Class A/B
  requests.

When comparing against another engine, pin the dataset, recall target, cache
state, concurrency, and durability settings. A vector-only brute-force scan
against an IVF index, or a warm in-process database against a cold HTTP service,
is not an apples-to-apples comparison.

[`perf/`](perf/README.md) contains a reproducible, exact-ground-truth
iso-recall comparison against Qdrant, with the measured
[results](perf/RESULTS.md) and their threats to validity.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Deployment](docs/DEPLOYMENT.md)
- [Control plane](docs/CONTROL_PLANE.md)
- [State machines](docs/STATE_MACHINES.md)
- [Verification notes](docs/FORMAL_VERIFICATION.md)
- [Third-party licenses](THIRD_PARTY_LICENSES.md)

## License

Apache-2.0. See [`LICENSE`](LICENSE).
