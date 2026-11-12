#!/usr/bin/env python3
"""End-to-end smoke test for the turbofish HTTP API v0 (Python SDK).

Usage:
    python3 test_e2e.py http://127.0.0.1:8080 [namespace]

Scenario:
    1. create namespace with the kuromoji tokenizer
    2. write 3 rows (Japanese text incl. 食べました / 服装 + 4-dim vectors)
    3. query text=食べる  -> assert FTS hits (id 1 among them)
    4. query vector [1,0,0,0] -> assert nearest id is 1
    5. health -> assert num_docs == 3, fts_tokenizer == kuromoji

A uniquely-named namespace is used by default so the script is safe to re-run;
pass argv[2] to pin a namespace instead. Exit code 0 = PASS, non-zero = FAIL.
"""

import sys
import time

from turbofish_client import TurboFishClient, TurboFishError


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python3 test_e2e.py <endpoint> [namespace]", file=sys.stderr)
        return 2
    endpoint = sys.argv[1]
    ns = sys.argv[2] if len(sys.argv) > 2 else f"e2e_py_{int(time.time())}"
    client = TurboFishClient(endpoint, timeout=15)

    print(f"[1/7] create namespace {ns!r} with fts_tokenizer=kuromoji ...")
    out = client.create_namespace(ns, fts_tokenizer="kuromoji")
    assert out.get("ok") is True, f"create_namespace: expected ok=true, got {out}"
    assert out.get("ns") == ns, f"create_namespace: expected ns={ns!r}, got {out}"

    rows = [
        {
            "id": 1,
            "text": "今日は寿司を食べました",
            "vector": [1.0, 0.0, 0.0, 0.0],
            "category": "food",
            "ts": 1700000000,
            "public": True,
        },
        {
            "id": 2,
            "text": "新しい服装が欲しい",
            "vector": [0.0, 1.0, 0.0, 0.0],
            "category": "clothing",
            "ts": 1700000100,
            "public": True,
        },
        {
            "id": 3,
            "text": "ラーメンを食べに行きました",
            "vector": [0.9, 0.1, 0.0, 0.0],
            "category": "food",
            "ts": 1700000200,
            "public": True,
        },
    ]
    print(f"[2/7] write {len(rows)} rows (食べました / 服装 / 食べに行きました, 4-dim vectors) ...")
    wout = client.write(ns, rows)
    assert wout.get("ingested") == 3, f"write: expected ingested=3, got {wout}"
    assert isinstance(wout.get("head"), str) and wout["head"], f"write: missing head, got {wout}"

    print("[3/7] query text=食べる (kuromoji FTS) & assert enriched attributes ...")
    qout = client.query(ns, text="食べる", top_k=5)
    qrows = qout.get("rows", [])
    ids = [r.get("id") for r in qrows]
    assert qout.get("count", 0) >= 1 and len(qrows) >= 1, f"query text=食べる: no hits, got {qout}"
    assert 1 in ids, f"query text=食べる: expected id 1 (食べました) among hits, got ids={ids} out={qout}"
    # Assert enriched attributes (text, category)
    hit1 = next((r for r in qrows if r.get("id") == 1), None)
    assert hit1 is not None, f"expected hit with id 1, got {qrows}"
    assert hit1.get("text") == "今日は寿司を食べました", f"expected original text for id 1, got {hit1.get('text')}"
    assert hit1.get("category") == "food", f"expected category 'food' for id 1, got {hit1.get('category')}"

    print("[4/7] query vector=[1,0,0,0] top_k=1 & assert enriched attributes ...")
    vout = client.query(ns, vector=[1.0, 0.0, 0.0, 0.0], top_k=1)
    vrows = vout.get("rows", [])
    assert len(vrows) >= 1 and vrows[0].get("id") == 1, f"query vector: expected nearest id 1, got {vout}"
    assert vrows[0].get("text") == "今日は寿司を食べました", f"expected original text, got {vrows[0].get('text')}"
    assert vrows[0].get("category") == "food", f"expected original category, got {vrows[0].get('category')}"

    print("[5/7] hybrid_search with attribute projection ...")
    hout_proj = client.hybrid_search(
        ns,
        text="食べる",
        vector=[1.0, 0.0, 0.0, 0.0],
        top_k=2,
        attributes=["text", "category"],
    )
    hrows = hout_proj.get("rows", [])
    assert len(hrows) >= 1, f"hybrid_search returned no rows: {hout_proj}"
    for hr in hrows:
        assert "id" in hr and "score" in hr, f"row missing id/score: {hr}"
        assert "text" in hr or "category" in hr, f"row missing projected attributes: {hr}"
        assert "ts" not in hr, f"ts attribute leaked despite projection: {hr}"
        assert "public" not in hr, f"public attribute leaked despite projection: {hr}"

    print("[6/7] batch_upsert and batch_delete helpers ...")
    extra_rows = [
        {
            "id": 100,
            "text": "うどんを食べました",
            "vector": [0.8, 0.2, 0.0, 0.0],
            "category": "food",
            "ts": 1700000300,
            "public": True,
        },
        {
            "id": 101,
            "text": "スニーカーを買いました",
            "vector": [0.0, 0.8, 0.2, 0.0],
            "category": "clothing",
            "ts": 1700000400,
            "public": True,
        },
    ]
    up_res = client.batch_upsert(ns, extra_rows, batch_size=1)
    assert up_res.get("ingested") == 2, f"batch_upsert: expected ingested=2, got {up_res}"
    assert up_res.get("batches") == 2, f"batch_upsert: expected batches=2, got {up_res}"

    del_res = client.batch_delete(ns, [100, 101], batch_size=1)
    assert del_res.get("deleted") == 2, f"batch_delete: expected deleted=2, got {del_res}"
    assert del_res.get("batches") == 2, f"batch_delete: expected batches=2, got {del_res}"

    print("[7/7] health ...")
    hout = client.health(ns)
    assert hout.get("ns") == ns, f"health: expected ns={ns!r}, got {hout}"
    assert hout.get("num_docs") == 3, f"health: expected num_docs=3, got {hout}"
    assert hout.get("fts_tokenizer") == "kuromoji", f"health: expected kuromoji, got {hout}"

    print(f"PASS: e2e OK against {endpoint} (ns={ns}, num_docs={hout.get('num_docs')}, head={hout.get('head')})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except TurboFishError as exc:
        print(f"E2E FAILED: TurboFishError status={exc.status} body={exc.body}", file=sys.stderr)
        sys.exit(1)
    except AssertionError as exc:
        print(f"E2E FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
