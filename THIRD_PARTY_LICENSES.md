# Third-Party Open Source Licenses & Attribution Notice

This document provides a comprehensive and exhaustive record of all third-party open-source software, ported algorithms, adapted mathematical models, external specifications, standards, and libraries incorporated in, ported to, or referenced by **Turbofish** (`seekpond/v1`).

Turbofish is released under the **Apache License, Version 2.0**. To maintain strict compliance with all upstream open-source licenses and to prevent any copyright or intellectual property infringement, this document details upstream project identities, source repositories, copyright holders, applicable licenses, descriptions of adaptations, and full verbatim license texts.

---

## Table of Contents

1. [Open Source Inventory Matrix](#1-open-source-inventory-matrix)
2. [Detailed Subsystem Audits & Technical Adaptations](#2-detailed-subsystem-audits--technical-adaptations)
   - [2.1 Roaring Bitmap Compression](#21-roaring-bitmap-compression)
   - [2.2 CJK Full-Text Search Tokenization & Morphological Analysis](#22-cjk-full-text-search-tokenization--morphological-analysis)
   - [2.3 Amazon S3 Protocol Client & SigV4 Request Signer](#23-amazon-s3-protocol-client--sigv4-request-signer)
   - [2.4 libcurl Native HTTP Transport](#24-libcurl-native-http-transport)
   - [2.5 Cryptographic & Hash Functions (SHA-256 & HMAC)](#25-cryptographic--hash-functions-sha-256--hmac)
   - [2.6 Information Retrieval: Okapi BM25 & Block-Max WAND](#26-information-retrieval-okapi-bm25--block-max-wand)
   - [2.7 Vector Similarity Search: IVF, K-Means & Quantization (SQ8 & PQ16)](#27-vector-similarity-search-ivf-k-means--quantization-sq8--pq16)
   - [2.8 Box-Muller Gaussian Sampling & Lognormal Latency Simulation](#28-box-muller-gaussian-sampling--lognormal-latency-simulation)
   - [2.9 Non-Cryptographic Hashing & PRNG Primitives](#29-non-cryptographic-hashing--prng-primitives)
   - [2.10 Identifier Generation: Crockford Base32 & ULID](#210-identifier-generation-crockford-base32--ulid)
   - [2.11 ClickHouse Compact Part File Format & MergeTree Architecture](#211-clickhouse-compact-part-file-format--mergetree-architecture)
   - [2.12 Binary Serialization: LEB128 & Protocol Buffers Varint](#212-binary-serialization-leb128--protocol-buffers-varint)
   - [2.13 IEEE 754-2008 Half-Precision Floating Point (Float16)](#213-ieee-754-2008-half-precision-floating-point-float16)
   - [2.14 MoonBit Async Structured Concurrency Runtime](#214-moonbit-async-structured-concurrency-runtime)
   - [2.15 Client SDKs & Development Tooling](#215-client-sdks--development-tooling)
   - [2.16 C Native Kernels & POSIX System Interfaces](#216-c-native-kernels--posix-system-interfaces)
3. [Full Verbatim License Texts](#3-full-verbatim-license-texts)
   - [Apache License, Version 2.0](#apache-license-version-20)
   - [The MIT License (MIT)](#the-mit-license-mit)
   - [The curl License](#the-curl-license)
   - [The BSD 3-Clause License](#the-bsd-3-clause-license)
   - [Creative Commons Zero v1.0 Universal (CC0 1.0)](#creative-commons-zero-v10-universal-cc0-10)

---

## 1. Open Source Inventory Matrix

| Component / Subsystem | Repository File(s) | Upstream Project / Origin | Copyright Holders / Authors | Upstream License | Usage Classification |
|---|---|---|---|---|---|
| **Roaring Bitmap** | `format/roaring.mbt`<br>`format/roaring_wbtest.mbt`<br>`mtree/engine.mbt` | [CRoaring](https://github.com/RoaringBitmap/CRoaring)<br>[RoaringBitmap](https://github.com/RoaringBitmap/RoaringBitmap) | Daniel Lemire, Owen Kaser, Nathan Kurz, Luca Deri | Apache-2.0 / MIT | Algorithmic Port & 64-bit Adaptation |
| **CJK Tokenizer (smartcn)** | `core/cjk_tokenizer.mbt`<br>`core/tokenize.mbt` | [Apache Lucene](https://github.com/apache/lucene) (SmartCN)<br>[alyze-cjk](https://github.com/turbopuffer/alyze) | Apache Software Foundation<br>Turbopuffer, Inc.<br>ICTCLAS (CAS) | Apache-2.0 | Algorithmic Port & Dictionary Seed |
| **CJK Tokenizer (kuromoji)** | `core/cjk_tokenizer.mbt` | [Apache Lucene](https://github.com/apache/lucene) (Kuromoji)<br>MeCab / mecab-ipadic | Atilika Inc. (Christian Moen)<br>Apache Software Foundation | Apache-2.0 / BSD | Morphological Rules & Dictionary Seed |
| **CJK Tokenizer (nori)** | `core/cjk_tokenizer.mbt` | [Apache Lucene](https://github.com/apache/lucene) (Nori)<br>[mecab-ko-dic](https://bitbucket.org/eunjeon/mecab-ko-dic) | Apache Software Foundation<br>Eunjeon Project (Yongun Deok et al.) | Apache-2.0 / BSD-3-Clause | Morphological Rules & Josa Stripping |
| **Text Tokenizer Pipeline** | `core/tokenize.mbt`<br>`REPORT.md` | [alyze](https://github.com/turbopuffer/alyze) | Turbopuffer, Inc. | MIT | Architecture Alignment |
| **AWS SigV4 Signer** | `s3store/sigv4.mbt`<br>`s3store/s3_wbtest.mbt` | [AWS SigV4 Specification & Test Suite](https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html) | Amazon Web Services, Inc. / Amazon.com, Inc. | Apache-2.0 | Protocol Implementation & Test Vectors |
| **HTTP Client Transport** | `s3http/s3http.c`<br>`s3http/s3http_native.mbt` | [curl / libcurl](https://curl.se) | Daniel Stenberg & contributors | curl (MIT/X variant) | Native C FFI Binding |
| **SHA-256** | `s3store/sha256.mbt`<br>`s3store/s3_wbtest.mbt` | NIST FIPS 180-4 | National Institute of Standards and Technology (NIST) | Public Domain (US Gov) | Algorithm Implementation |
| **HMAC-SHA256** | `s3store/hmac.mbt`<br>`s3store/s3_wbtest.mbt` | IETF RFC 2104 / RFC 4231 | H. Krawczyk, M. Bellare, R. Canetti, M. Nystrom | Public Domain / IETF RFC | Standard Implementation |
| **Okapi BM25** | `query/bm25.mbt`<br>`core/types.mbt` | Okapi BM25 (TREC-3, 1994) | S. E. Robertson, S. Walker, S. Jones, et al. | Public Domain / Literature | Ranking Function Implementation |
| **Block-Max WAND** | `query/bm25.mbt`<br>`format/blockmax.mbt` | Block-Max WAND (SIGIR 2011)<br>WAND (CIKM 2003) | Shuai Ding, Torsten Suel<br>Andrei Z. Broder et al. | Public Domain / Literature | Dynamic Pruning Algorithm |
| **Reciprocal Rank Fusion (RRF)** | `query/vecq.mbt` | RRF (SIGIR 2009) | G. V. Cormack, C. L. A. Clarke, S. Buettcher | Public Domain / Literature | Hybrid Fusion Algorithm |
| **K-Means / Lloyd's Algorithm** | `build/kmeans.mbt` | Lloyd's K-Means (1957/1982)<br>Spherical K-Means (2001) | Stuart P. Lloyd<br>Inderjit S. Dhillon, Dharmendra S. Modha | Public Domain / Literature | Cosine Clustering Algorithm |
| **Vector IVF & Quantization** | `format/vec.mbt`<br>`format/quant.mbt`<br>`build/pq.mbt`<br>`query/vecq.mbt` | [Faiss](https://github.com/facebookresearch/faiss)<br>Product Quantization (TPAMI 2011) | Meta Platforms, Inc. and affiliates<br>H. Jégou, M. Douze, C. Schmid | MIT | Algorithmic Port (SQ8, PQ16, ADC) |
| **Box-Muller Gaussian Sampling** | `simstore/latency.mbt` | Box-Muller Transform (1958) | George E. P. Box, Mervin E. Muller | Public Domain / Literature | Random Variate Generator |
| **Mulberry32 PRNG** | `core/vecmath.mbt` | Mulberry32 PRNG (2017) | Tommy Ettinger | Public Domain / CC0-1.0 | PRNG Implementation |
| **MurmurHash3 (fmix64)** | `format/bloom.mbt` | MurmurHash3 Finalizer | Austin Appleby | Public Domain / CC0-1.0 | Bit Finalizer Function |
| **FNV-1a Hash** | `format/bloom.mbt` | FNV Hash (1991) | Glenn Fowler, Landon Curt Noll, Phong Vo | Public Domain | Hash Function |
| **Bloom Filter Double Hashing** | `format/bloom.mbt` | Kirsch-Mitzenmacher (ESA 2006)<br>Burton Bloom (1970) | Adam Kirsch, Michael Mitzenmacher<br>Burton H. Bloom | Public Domain / Literature | Probabilistic Indexing |
| **Crockford Base32** | `core/ulid.mbt` | Crockford's Base32 (2002) | Douglas Crockford | Public Specification | Encoding Implementation |
| **ULID Monotonic ID** | `core/ulid.mbt` | [ULID Spec](https://github.com/ulid/spec)<br>[alizain/ulid](https://github.com/alizain/ulid) | Alizain Feerasta | MIT (impl) / GPL-3.0 (spec) | Monotonic Sortable ID Generator |
| **ClickHouse Compact Part & MergeTree** | `format/compact.mbt`<br>`mtree/engine.mbt`<br>`mtree/compactor.mbt` | [ClickHouse](https://github.com/ClickHouse/ClickHouse) | ClickHouse, Inc.<br>Yandex LLC | Apache-2.0 | Architectural & Layout Adaptation |
| **LEB128 / Protobuf Varint** | `core/binrw.mbt`<br>`format/fastread.mbt` | DWARF LEB128<br>[Protocol Buffers](https://github.com/protocolbuffers/protobuf) | DWARF Committee<br>Google LLC | Apache-2.0 / BSD-3-Clause | Variable-Byte Integer Encoding |
| **IEEE 754-2008 Float16 (binary16)** | `core/f16.mbt` | IEEE 754-2008 Standard | IEEE | International Standard | Software Conversion Routine |
| **moonbitlang/async** | `moon.mod`<br>`.mooncakes/moonbitlang/async` | [moonbitlang/async](https://github.com/moonbitlang/async) | International Digital Economy Academy (IDEA) | Apache-2.0 | Package Dependency (v0.22.9) |
| **TypeScript Client & Compiler** | `sdk/typescript/package.json`<br>`sdk/typescript/` | [TypeScript](https://github.com/microsoft/TypeScript) | Microsoft Corporation | Apache-2.0 | Development Dependency |
| **Python Client** | `sdk/python/` | Python 3 Standard Library | Python Software Foundation | PSF License | Pure Standard Library |
| **POSIX System Calls & Libc** | `fsstore/ffi_native.mbt`<br>`cmd/idxrepo/idxfs.c`<br>`core/entropy.c` | POSIX.1-2008 / Standard C | Standard Interfaces | System API | FFI Bindings (`open`, `read`, `write`, `getrandom`, `arc4random_buf`) |

---

## 2. Detailed Subsystem Audits & Technical Adaptations

### 2.1 Roaring Bitmap Compression

- **Location**: `format/roaring.mbt`, `format/roaring_wbtest.mbt`, `mtree/engine.mbt`
- **Origin**: Daniel Lemire, Owen Kaser, Nathan Kurz, Luca Deri. *"Consistently faster and smaller compressed bitmaps with Roaring"*, Software: Practice and Experience (2016).
- **Upstream Repositories**:
  - CRoaring (C/C++): [https://github.com/RoaringBitmap/CRoaring](https://github.com/RoaringBitmap/CRoaring) (Apache-2.0 / MIT)
  - RoaringBitmap (Java): [https://github.com/RoaringBitmap/RoaringBitmap](https://github.com/RoaringBitmap/RoaringBitmap) (Apache-2.0)
- **Copyright Holders**: Copyright (c) 2013-2024 Daniel Lemire, Owen Kaser, and contributors.
- **Upstream License**: Apache License 2.0 / MIT Dual License.
- **Technical Adaptation**:
  Turbofish implements a specialized 64-bit variant of Roaring Bitmap tailored for document soft deletion and tombstone tracking.
  1. **64-bit Partitioning**: Identifiers are partitioned into a high 48-bit container prefix (`id >> 16`) and a low 16-bit intra-container index (`id & 0xFFFF`).
  2. **Array vs. Bitmap Containers**: Adheres to the canonical threshold of 4,096 elements (`ROAR_ARRAY_MAX = 4096`). Containers with `< 4096` entries use an Array Container (sorted uint16 array); containers with `>= 4096` entries convert into a dense Bitmap Container consisting of 1,024 uint64 words ($1024 \times 64 = 65,536$ bits = 8,192 bytes). Run containers are intentionally omitted for optimal serialization compactness and predictable tombstone density.
  3. **Zero-Allocation Membership Testing**: `roaring_contains(bs: Bytes, id: UInt64) -> Bool` conducts in-place binary searching over containers and array slices, and direct bit testing `((word >> bit) & 1UL) != 0UL` over bitmap containers without allocating runtime heap objects.

---

### 2.2 CJK Full-Text Search Tokenization & Morphological Analysis

- **Location**: `core/cjk_tokenizer.mbt`, `core/tokenize.mbt`
- **Origin & Heritage**:
  - **Turbopuffer `alyze` / `alyze-cjk`**: [https://github.com/turbopuffer/alyze](https://github.com/turbopuffer/alyze). Turbopuffer's high-performance full-text search tokenization engine and CJK tokenization specification. Copyright (c) Turbopuffer, Inc. Licensed under MIT / Apache-2.0.
  - **SmartChineseAnalyzer (SmartCN)**: Apache Lucene analysis module (`org.apache.lucene.analysis.cn.smart`). Derived from ICTCLAS (Institute of Computing Technology, Chinese Academy of Sciences). Copyright (c) 1999-2024 The Apache Software Foundation. Licensed under Apache-2.0.
  - **Kuromoji Japanese Analyzer**: Apache Lucene Japanese analysis module (`org.apache.lucene.analysis.ja`). Developed by Atilika Inc. (Christian Moen) and the Apache Software Foundation, based on MeCab and `mecab-ipadic`. Copyright (c) 2011-2024 Atilika Inc. and The Apache Software Foundation. Licensed under Apache-2.0.
  - **Nori Korean Analyzer**: Apache Lucene Korean analysis module (`org.apache.lucene.analysis.ko`). Developed by Jim Ferenczi and the Apache Software Foundation, utilizing `mecab-ko-dic`. Copyright (c) 2018-2024 The Apache Software Foundation. Dictionary copyright (c) 2013-2015 Eunjeon Project. Licensed under Apache-2.0 and BSD 3-Clause.
- **Technical Adaptation**:
  1. **SmartCN (Chinese)**: Implements maximum matching dictionary segmentation (`zh_emit`) utilizing an embedded deterministic seed lexicon of high-frequency words, with automatic single-character unigram fallback for out-of-vocabulary (OOV) Han characters.
  2. **Kuromoji (Japanese)**: Implements dictionary-based morphological analysis and inflection normalization (`ja_inflections`). Maps conjugated surface verb and adjective variants (Ichidan verbs, Godan verbs with *i-row* and *a-row* shifts, Sa-hen `する`, Ka-hen `来る`, and I-adjectives, e.g. `食べました` -> `食べる`, `書いた` -> `書く`) back to base dictionary forms. Aggregates contiguous Katakana sequences into single loanword semantic tokens.
  3. **Nori (Korean)**: Implements Hangul eojeol morphological decomposition (`ko_emit`), stripping postpositional grammatical particles (*josa*, e.g. `에서는`, `으로는`, `을`, `를`, `은`, `는`, `이`, `가`) in longest-match order and normalizing conjugated predicate forms (e.g. `먹습니다` -> `먹다`) to base dictionary lemmas.
  4. **Determinism**: Seed lexicons and inflection tables are statically initialized once in memory, operating without disk I/O, external network calls, or non-deterministic hash iterations.

---

### 2.3 Amazon S3 Protocol Client & SigV4 Request Signer

- **Location**: `s3store/sigv4.mbt`, `s3store/s3store.mbt`, `s3store/s3_wbtest.mbt`
- **Origin**: Amazon Web Services (AWS) Signature Version 4 Signing Process.
- **Upstream Specification & Test Assets**:
  - AWS SigV4 Documentation: [https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html](https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html)
  - AWS SigV4 Test Suite: `https://docs.aws.amazon.com/general/latest/gr/samples/aws-sig-v4-test-suite.zip`
- **Copyright Holders**: Copyright (c) Amazon.com, Inc. or its affiliates. All Rights Reserved.
- **Upstream License**: Apache License 2.0.
- **Technical Adaptation**:
  1. **Canonical Request Building**: Computes RFC 3986 percent-encoded URI paths, canonical query string with lexicographical UTF-8 byte-order parameter sorting (`byte_order_compare`), lowercased trimmed canonical header blocks, and SHA-256 payload digests.
  2. **Hierarchical Key Derivation**: Implements four-tier HMAC-SHA256 signing key derivation:
     $$\text{kDate} = \text{HMAC-SHA256}(\text{"AWS4"} + \text{SecretKey}, \text{DateStamp})$$
     $$\text{kRegion} = \text{HMAC-SHA256}(\text{kDate}, \text{Region})$$
     $$\text{kService} = \text{HMAC-SHA256}(\text{kRegion}, \text{Service})$$
     $$\text{kSigning} = \text{HMAC-SHA256}(\text{kService}, \text{"aws4\_request"})$$
  3. **Verification**: Validated against official AWS SigV4 test vectors, including `get-vanilla` (IAM / AKIDEXAMPLE) and standard S3 GET Range / PUT test scenarios.

---

### 2.4 libcurl Native HTTP Transport

- **Location**: `s3http/s3http.c`, `s3http/s3http_native.mbt`
- **Origin**: The curl / libcurl Project: [https://curl.se](https://curl.se)
- **Copyright Holders**: Copyright (c) 1996 - 2026, Daniel Stenberg, <daniel@haxx.se>, and many contributors.
- **Upstream License**: The curl License (MIT/X derivate, SPDX identifier: `curl`).
- **Technical Adaptation**:
  `s3http.c` acts as a C FFI bridge between MoonBit native binaries and the host's `libcurl` installation (`<curl/curl.h>`). It initializes global state (`curl_global_init`), manages curl easy handles (`curl_easy_init`, `curl_easy_setopt`), builds header linked lists (`curl_slist_append`), dynamically buffers responses (`write_body_cb`, `write_header_cb`), and formats RFC 1123 / ISO 8601 AMZ dates via `gmtime_r` and `strftime`.

---

### 2.5 Cryptographic & Hash Functions (SHA-256 & HMAC)

- **Location**: `s3store/sha256.mbt`, `s3store/hmac.mbt`, `s3store/s3_wbtest.mbt`
- **Origin & Standards**:
  - **SHA-256**: National Institute of Standards and Technology (NIST) FIPS PUB 180-4 *"Secure Hash Standard (SHS)"* (2015). Public Domain (Work of the United States Government under 17 U.S.C. § 105).
  - **HMAC-SHA256**: IETF RFC 2104 *"HMAC: Keyed-Hashing for Message Authentication"* (H. Krawczyk, M. Bellare, R. Canetti, 1997) and RFC 4231 *"Identifiers and Test Vectors for HMAC-SHA-224, HMAC-SHA-256, HMAC-SHA-384, and HMAC-SHA-512"* (M. Nystrom, 2005).
- **Technical Adaptation**:
  - Pure MoonBit implementation of 32-bit word SHA-256 compression with 64 round constants $K_{256}$ derived from fractional parts of prime cube roots.
  - Message padding, bit rotations (`rotr32`), and state scheduling without native cryptographic C dependencies.
  - HMAC key normalization (hashing keys $> 64$ bytes, zero-padding keys $< 64$ bytes) and inner/outer XOR masking (`0x36` and `0x5c`).
  - Formally validated against NIST FIPS 180-4 test vectors and RFC 4231 test vectors 1 through 3.

---

### 2.6 Information Retrieval: Okapi BM25 & Block-Max WAND

- **Location**: `query/bm25.mbt`, `format/fts.mbt`, `format/blockmax.mbt`, `core/types.mbt`
- **Origin & Literature**:
  - **Okapi BM25**: Stephen E. Robertson, Steve Walker, Susan Jones, Micheline Hancock-Beaulieu, Mike Gatford. *"Okapi at TREC-3"*, Proceedings of the Third Text REtrieval Conference (TREC 1994).
  - **Block-Max WAND**: Shuai Ding, Torsten Suel. *"Faster top-k document retrieval using block-max indexes"*, Proceedings of the 34th international ACM SIGIR conference (SIGIR 2011).
  - **WAND Operator**: Andrei Z. Broder, David Carmel, Michael Herscovici, Aya Soffer, Jason Zien. *"Efficient query evaluation using a two-level retrieval process"*, ACM CIKM (2003).
  - **Reciprocal Rank Fusion (RRF)**: Gordon V. Cormack, Charles L. A. Clarke, Stefan Buettcher. *"Reciprocal rank fusion outperforms condorcet and individual rank learning methods"*, ACM SIGIR (2009).
- **Technical Adaptation**:
  1. **BM25 Formula**: Implements non-negative Robertson-Spärck Jones IDF and Okapi BM25 term scoring with standard parameterization ($k_1 = 1.2$, $b = 0.75$):
     $$\text{IDF}(q_i) = \ln\left(1.0 + \frac{N - \text{df}_i + 0.5}{\text{df}_i + 0.5}\right)$$
     $$\text{Score}(D, Q) = \sum_{q_i \in Q} \text{IDF}(q_i) \cdot \frac{\text{TF}(q_i, D) \cdot (k_1 + 1)}{\text{TF}(q_i, D) + k_1 \cdot \left(1 - b + b \cdot \frac{|D|}{\text{avgdl}}\right)}$$
  2. **Block-Max Indexing (`SPNDBLK1`)**: Stores per-block upper bounds ($\text{max\_tf}$, $\text{min\_dl}$) in inverted index postings blocks (default block size 128).
  3. **WAND Pruning**: `bm25_segment_wand` sorts term posting iterators by current document ID and evaluates block-level upper bound scores against the current running top-$k$ threshold, pruning non-competitive document blocks without range-reading or scoring individual postings.
  4. **RRF Hybrid Fusion**: Combines ranked BM25 candidates and vector candidates using $k=60$: $\text{Score}(d) = \sum \frac{1}{60 + \text{rank}(d)}$.

---

### 2.7 Vector Similarity Search: IVF, K-Means & Quantization (SQ8 & PQ16)

- **Location**: `build/kmeans.mbt`, `format/vec.mbt`, `format/quant.mbt`, `build/pq.mbt`, `query/vecq.mbt`, `core/vecmath.mbt`
- **Origin & Literature**:
  - **K-Means / Lloyd's Algorithm**: Stuart P. Lloyd. *"Least squares quantization in PCM"*, IEEE Transactions on Information Theory (1982 / Bell Labs 1957).
  - **Spherical K-Means**: Inderjit S. Dhillon, Dharmendra S. Modha. *"Concept decompositions for large sparse text data using clustering"*, Machine Learning (2001).
  - **Product Quantization (PQ)**: Hervé Jégou, Matthijs Douze, Cordelia Schmid. *"Product Quantization for Nearest Neighbor Search"*, IEEE Transactions on Pattern Analysis and Machine Intelligence (TPAMI 2011).
  - **Faiss**: Facebook AI Similarity Search. [https://github.com/facebookresearch/faiss](https://github.com/facebookresearch/faiss). Copyright (c) Meta Platforms, Inc. and affiliates. MIT License.
- **Technical Adaptation**:
  1. **IVF Centroid Training**: Lloyd's k-means iteration with cosine distance and L2-normalization. Centers are initialized via deterministic partial Fisher-Yates shuffling (`@core.Rng(42)`). Empty clusters are reseeded dynamically from the sample set.
  2. **Scalar Quantization (SQ8)**: Uniform 8-bit linear min-max quantization (`format/quant.mbt`). Stores per-dimension minimums and inverse scaling factors $\text{inv\_scale} = \frac{255}{\max - \min}$. Quantized codes: $\text{code} = \text{clamp}(\text{round}((v - \min) \cdot \text{inv\_scale}), 0, 255)$.
  3. **Product Quantization (PQ16)**: Vectors of dimension $D$ are split into $m=16$ orthogonal subvectors of dimension $d_{sub} = D / 16$. Each subspace trains $k=256$ centroids. Asymmetric Distance Computation (ADC) builds a query Look-Up Table (LUT) of size $m \times 256$, accumulating distances via direct table lookups during search.

---

### 2.8 Box-Muller Gaussian Sampling & Lognormal Latency Simulation

- **Location**: `simstore/latency.mbt`
- **Origin**: George E. P. Box, Mervin E. Muller. *"A Note on the Generation of Random Normal Deviates"*, The Annals of Mathematical Statistics (1958).
- **Legal Status**: Public Domain scientific algorithm.
- **Technical Adaptation**:
  Converts two independent uniform random variables $u_1, u_2 \in (0, 1)$ into a standard normal variable $Z \sim \mathcal{N}(0, 1)$:
  $$Z = \sqrt{-2 \ln u_1} \cdot \cos(2\pi u_2)$$
  Lognormal latency samples are generated deterministically:
  $$\text{Latency} = p_{50} \cdot \exp(\sigma \cdot Z)$$
  This replaces bounded approximation models (e.g. Irwin-Hall) with true heavy-tailed Gaussian tails for high-fidelity S3 TTFB and NVMe latency emulation.

---

### 2.9 Non-Cryptographic Hashing & PRNG Primitives

- **Location**: `core/vecmath.mbt`, `format/bloom.mbt`
- **Origin & Authors**:
  - **Mulberry32 PRNG**: Tommy Ettinger (2017). Public Domain / CC0-1.0. A high-quality 32-bit state PRNG with period $2^{32}$.
  - **MurmurHash3 (fmix64)**: Austin Appleby. MurmurHash3 64-bit finalizer. Public Domain / CC0-1.0.
  - **FNV-1a 64-bit**: Glenn Fowler, Landon Curt Noll, Kiem-Phong Vo (1991). Fowler-Noll-Vo hash function. Public Domain.
  - **Kirsch-Mitzenmacher Optimization**: Adam Kirsch, Michael Mitzenmacher. *"Less Hashing, Same Performance: Building a Better Bloom Filter"*, European Symposium on Algorithms (ESA 2006).
- **Technical Adaptation**:
  - `core/vecmath.mbt` implements `Mulberry32` (`Rng`) using additive increment `0x6D2B79F5U` and bitwise mixing for deterministic test vector and benchmark sampling.
  - `format/bloom.mbt` combines FNV-1a with Murmur3 `fmix64` to produce two independent 64-bit hashes $h_1, h_2$, applying Kirsch-Mitzenmacher double hashing:
    $$\text{bit\_index}(i) = (h_1 + i \cdot h_2) \pmod m$$
    to construct and query segment-level Bloom filters with $k=7$ hash functions without computing $k$ separate hashes.

---

### 2.10 Identifier Generation: Crockford Base32 & ULID

- **Location**: `core/ulid.mbt`
- **Origin**:
  - **Crockford's Base32**: Douglas Crockford (2002). [https://www.crockford.com/base32.html](https://www.crockford.com/base32.html). Uses alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (excluding I, L, O, U to avoid visual ambiguity).
  - **ULID Specification**: Alizain Feerasta. [https://github.com/ulid/spec](https://github.com/ulid/spec), [https://github.com/alizain/ulid](https://github.com/alizain/ulid). Copyright (c) 2016 Alizain Feerasta. MIT License.
- **Technical Adaptation**:
  Monotonically incrementing 64-bit counter encoded into fixed 13-character Crockford Base32 strings. Ensures lexicographical string sorting strictly equals numerical sequence order for segment IDs (`seg-0000000000001`), manifest IDs, and centroid versions.

---

### 2.11 ClickHouse Compact Part File Format & MergeTree Architecture

- **Location**: `format/compact.mbt`, `mtree/engine.mbt`, `mtree/compactor.mbt`, `mtree/cached_manifest.mbt`
- **Origin**: ClickHouse Columnar Database: [https://github.com/ClickHouse/ClickHouse](https://github.com/ClickHouse/ClickHouse).
- **Copyright Holders**: Copyright (c) 2016-2024 ClickHouse, Inc., (c) 2008-2016 Yandex LLC.
- **Upstream License**: Apache License 2.0.
- **Technical Adaptation**:
  1. **Compact Part Storage Layout**: In ClickHouse, `Compact` parts consolidate all columns into a single file (`data.bin`) with index marks (`data.mrk3`) to prevent file descriptor and small-file explosion. Turbofish adopts this design for S3: packing all data columns, inverted index postings, doc length vectors, and IVF vector slices into a single S3 object (`part-{id}.bin`).
  2. **Footer and Fixed Trailer Indexing**: The compact part file concludes with a Section Dictionary Footer (`SPNDFOOT`) and a 16-byte fixed Trailer (`CPT1`), containing `(footer_offset: u64, footer_length: u32, magic: [4]byte)`. Readers fetch the 16-byte trailer and footer via HTTP Range GET, indexing individual columns and sections without performing multi-part S3 `LIST` or full-file `GET` operations.
  3. **MergeTree Compaction & L0 Ingestion**: High-frequency writes append L0 delta parts. Background compactor merges small parts into optimized L1 baseline parts based on part count ($\ge 4$) and tombstone ratio ($\ge 20\%$) thresholds.

---

### 2.12 Binary Serialization: LEB128 & Protocol Buffers Varint

- **Location**: `core/binrw.mbt`, `format/fastread.mbt`
- **Origin**: DWARF Debugging Standard (LEB128) & Google Protocol Buffers: [https://github.com/protocolbuffers/protobuf](https://github.com/protocolbuffers/protobuf).
- **Copyright Holders**: Copyright (c) Google LLC.
- **Upstream License**: Apache License 2.0 / BSD 3-Clause.
- **Technical Adaptation**:
  Implements little-endian variable-length unsigned integer serialization (`read_uvarint`, `write_uvarint`, `fa_uvarint`). Uses 7 payload bits per byte with bit 7 (`0x80`) serving as continuation flag, providing compact delta encoding for document IDs and term frequencies in postings lists.

---

### 2.13 IEEE 754-2008 Half-Precision Floating Point (Float16)

- **Location**: `core/f16.mbt`
- **Origin**: IEEE 754-2008 Standard for Floating-Point Arithmetic (binary16 format).
- **Legal Status**: International Technical Standard (IEEE).
- **Technical Adaptation**:
  Software bitwise conversion between IEEE single-precision 32-bit floats (`Float`) and half-precision 16-bit floats (`UInt16`). Full support for 1 sign bit, 5 exponent bits (bias 15), 10 mantissa bits, infinities, NaNs, and subnormal/denormal numbers, cutting vector storage size by 50% relative to standard 32-bit floats.

---

### 2.14 MoonBit Async Structured Concurrency Runtime

- **Location**: `moon.mod`, `.mooncakes/moonbitlang/async`
- **Origin**: MoonBit Async Library: [https://github.com/moonbitlang/async](https://github.com/moonbitlang/async).
- **Copyright Holders**: Copyright (c) 2024 International Digital Economy Academy (IDEA).
- **Upstream License**: Apache License 2.0.
- **Technical Adaptation**:
  Used directly as package dependency `moonbitlang/async@0.22.9` for cooperative asynchronous structured task groups (`with_task_group`), non-blocking timers, and background compaction loops inside the standalone server (`cmd/serve/main.mbt`).

---

### 2.15 Client SDKs & Development Tooling

- **Location**: `sdk/python/`, `sdk/typescript/`
- **Components**:
  - **Python SDK (`sdk/python/turbofish_client.py`)**: Authored natively using only the Python 3 standard library (`urllib.request`, `json`, `http.server`). Zero third-party runtime package dependencies.
  - **TypeScript SDK (`sdk/typescript/src/client.ts`)**: Released under the MIT License (`sdk/typescript/package.json`). Zero runtime dependencies (pure Node.js native `fetch`).
  - **TypeScript Compiler**: [https://github.com/microsoft/TypeScript](https://github.com/microsoft/TypeScript). Copyright (c) Microsoft Corporation. Apache-2.0. Used strictly as a development dependency (`devDependencies`).

---

### 2.16 C Native Kernels & POSIX System Interfaces

- **Location**: `benchx/kernel.c`, `cmd/idxrepo/idxfs.c`, `core/entropy.c`, `fsstore/ffi_native.mbt`
- **Origin & Standards**:
  - **POSIX.1-2008 / POSIX.1-2017**: Standardized Operating System Interfaces (IEEE Std 1003.1 / The Open Group). Standard interfaces for file I/O (`open`, `creat`, `read`, `write`, `lseek`, `close`, `unlink`, `rename`, `mkdir`, `opendir`, `readdir`, `stat`).
  - **Entropy & Randomness**: Linux `getrandom(2)` (Linux kernel, Linus Torvalds and contributors) and BSD/macOS `arc4random_buf(3)` (OpenBSD / Apple Inc.).
  - **Microbenchmark Kernel (`benchx/kernel.c`)**: Native C testing harness evaluating FFI parameter crossing and 8-accumulator ILP unrolled dot product.

---

## 3. Full Verbatim License Texts

The following sections reproduce the complete, verbatim license texts of the third-party open source licenses cited above.

---

### Apache License, Version 2.0

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```

---

### The MIT License (MIT)

```text
The MIT License (MIT)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

### The curl License

```text
COPYRIGHT AND PERMISSION NOTICE

Copyright (c) 1996 - 2026, Daniel Stenberg, <daniel@haxx.se>, and many 
contributors, see the THANKS file.

All rights reserved.

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright
notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
USE OR OTHER DEALINGS IN THE SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in this Software without prior written authorization of the copyright holder.
```

---

### The BSD 3-Clause License

```text
The BSD 3-Clause License

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

### Creative Commons Zero v1.0 Universal (CC0 1.0)

```text
Creative Commons Legal Code

CC0 1.0 Universal

    CREATIVE COMMONS CORPORATION IS NOT A LAW FIRM AND DOES NOT PROVIDE
    LEGAL SERVICES. DISTRIBUTION OF THIS DOCUMENT DOES NOT CREATE AN
    ATTORNEY-CLIENT RELATIONSHIP. CREATIVE COMMONS PROVIDES THIS
    INFORMATION ON AN "AS-IS" BASIS. CREATIVE COMMONS MAKES NO WARRANTIES
    REGARDING THE USE OF THIS DOCUMENT OR INFORMATION OR MATERIALS
    PROVIDED HEREUNDER, AND DISCLAIMS ALL LIABILITY FOR DAMAGES RESULTING
    FROM THE USE OF THIS DOCUMENT OR INFORMATION OR MATERIALS PROVIDED
    HEREUNDER.

Statement of Purpose

The laws of most jurisdictions throughout the world automatically confer
exclusive Copyright and Related Rights (defined below) upon the creator and
subsequent owner(s) (each and all, an "owner") of an original work of
authorship and/or a database (each, a "Work").

Certain owners wish to permanently relinquish those rights to a Work for the
purpose of contributing to a commons of creative, cultural and scientific
works ("Commons") that the public can reliably and without fear of later
claims of infringement build upon, modify, incorporate in other works, reuse
and redistribute as freely as possible in any form whatsoever and for any
purposes, including without limitation commercial purposes. These owners may
contribute to the Commons to promote the ideal of a free culture and the
further production of creative, cultural and scientific works, or to gain
reputation or greater distribution for their Work in part through the use and
efforts of others.

For these and/or other purposes and motivations, and without any expectation
of additional consideration or compensation, the person associating CC0 with a
Work (the "Affirmer"), to the extent that he or she is an owner of Copyright
and Related Rights in the Work, voluntarily elects to apply CC0 to the Work and
publicly distribute the Work under its terms, with knowledge of his or her
Copyright and Related Rights in the Work and the meaning and intended legal
effect of CC0 on those rights.

1. Copyright and Related Rights. A Work made available under CC0 may be
protected by copyright and related or neighboring rights ("Copyright and
Related Rights"). Copyright and Related Rights include, but are not limited
to, the following:
  i. the right to reproduce, adapt, distribute, perform, display, communicate,
     and translate a Work;
 ii. moral rights retained by the original author(s) and/or performer(s);
iii. publicity and privacy rights pertaining to a person's image or likeness
     depicted in a Work;
 iv. rights protecting against unfair competition in regards to a Work,
     subject to the limitations in paragraph 4(a), below;
  v. rights protecting the extraction, dissemination, use and reuse of data in
     a Work;
 vi. database rights (such as those arising under Directive 96/9/EC of the
     European Parliament and of the Council of 11 March 1996 on the legal
     protection of databases, and under any national implementation thereof,
     including any amended or successor version of such directive); and
vii. other similar, equivalent or corresponding rights throughout the world
     based on applicable law or treaty, and any national implementations
     thereof.

2. Waiver. To the greatest extent permitted by, but not in contravention of,
applicable law, Affirmer hereby overtly, fully, permanently, irrevocably and
unconditionally waives, abandons, and surrenders all of Affirmer's Copyright
and Related Rights and associated claims and causes of action, whether now
known or unknown (including existing as well as future claims and causes of
action), in the Work (i) in all territories worldwide, (ii) for the maximum
duration provided by applicable law or treaty (including future time
extensions), (iii) in any current or future medium and for any number of
copies, and (iv) for any purpose whatsoever, including without limitation
commercial, advertising or promotional purposes (the "Waiver"). Affirmer makes
the Waiver for the benefit of each member of the public at large and to the
detriment of Affirmer's heirs and successors, fully intending that such Waiver
shall not be subject to revocation, rescission, cancellation, termination, or
any other legal or equitable action to disrupt the quiet enjoyment of the Work
by the public as contemplated by Affirmer's express Statement of Purpose.

3. Public License Fallback. Should any part of the Waiver for any reason be
judged legally invalid or ineffective under applicable law, then the Waiver
shall be preserved to the maximum extent permitted taking into account
Affirmer's express Statement of Purpose. In addition, to the extent the Waiver
is so judged Affirmer hereby grants to each affected person a royalty-free,
non transferable, non sublicensable, non exclusive, irrevocable and
unconditional license to exercise Affirmer's Copyright and Related Rights in
the Work (i) in all territories worldwide, (ii) for the maximum duration
provided by applicable law or treaty (including future time extensions), (iii)
in any current or future medium and for any number of copies, and (iv) for any
purpose whatsoever, including without limitation commercial, advertising or
promotional purposes (the "License"). The License shall be deemed effective as
of the date CC0 was applied by Affirmer to the Work. Should any part of the
License for any reason be judged legally invalid or ineffective under
applicable law, such partial invalidity or ineffectiveness shall not invalidate
the remainder of the License, and in such case Affirmer hereby affirms that he
or she will not (i) exercise any of his or her remaining Copyright and Related
Rights in the Work or (ii) assert any associated claims and causes of action
with respect to the Work, in either case contrary to Affirmer's express
Statement of Purpose.

4. Limitations and Disclaimers.
  a. No trademark or patent rights held by Affirmer are waived, abandoned,
     surrendered, licensed or otherwise affected by this document.
  b. Affirmer offers the Work as-is and makes no representations or warranties
     of any kind concerning the Work, express, implied, statutory or
     otherwise, including without limitation warranties of title,
     merchantability, fitness for a particular purpose, non infringement, or
     the absence of latent or other defects, accuracy, or the present or
     absence of errors, whether or not discoverable, all to the greatest
     extent permissible under applicable law.
  c. Affirmer disclaims responsibility for clearing rights of other persons
     that may apply to the Work or any use thereof, including without
     limitation any person's Copyright and Related Rights in the Work.
     Further, Affirmer disclaims responsibility for obtaining any necessary
     consents, permissions or other rights required for any use of the Work.
  d. Affirmer understands and acknowledges that Creative Commons is not a
     party to this document and has no duty or obligation with respect to this
     CC0 or use of the Work.
```
