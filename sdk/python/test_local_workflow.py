"""Single-node local workflow test module for turbofish SDK.

Covers the full single-node local workflow matching Turbopuffer semantics:
1. Namespace initialization with tokenizer configuration
2. Batch document upserts with full attribute sets (text, vector, category, ts, public)
3. Full-text search (BM25), vector search, and hybrid search
4. Attribute projection (restricting returned fields to projected attributes)
5. Soft-deletion and query verification after deletion
6. Upsert mutation (updating existing documents)

Can run standalone against a running local server (TURBOFISH_ENDPOINT)
or autonomously via an embedded stateful single-node server.
"""

from __future__ import annotations

import json
import math
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

from turbofish_client import TurboFishClient, TurboFishError


class StatefulLocalServer:
    """Embedded single-node Turbofish server for local workflow testing."""

    def __init__(self):
        self.namespaces: Dict[str, Dict[str, Any]] = {}
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                rec = {
                    "method": self.command,
                    "path": self.path,
                    "body": raw.decode("utf-8") if raw else "",
                    "headers": dict(self.headers),
                }
                status, payload = outer.dispatch(rec)
                data = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = _handle
            do_POST = _handle

            def log_message(self, fmt, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def dispatch(self, rec: Dict[str, Any]) -> Tuple[int, Any]:
        parts = rec["path"].split("/")
        if len(parts) >= 5 and parts[1] == "v1" and parts[2] == "namespaces":
            ns = parts[3]
            action = parts[4]
            body = json.loads(rec["body"]) if rec["body"] else {}

            if ns not in self.namespaces:
                self.namespaces[ns] = {
                    "docs": {},  # id -> doc dict
                    "tokenizer": "word",
                    "head": "0000000000000001",
                    "seq": 1,
                }
            ns_data = self.namespaces[ns]

            if rec["method"] == "POST" and action == "create":
                tok = body.get("fts_tokenizer", "word")
                ns_data["tokenizer"] = tok
                return 200, {"ok": True, "ns": ns}

            if rec["method"] == "POST" and action == "write":
                rows = body.get("rows", [])
                deletes = body.get("deletes", [])
                for row in rows:
                    doc_id = row["id"]
                    ns_data["docs"][doc_id] = dict(row)
                for did in deletes:
                    ns_data["docs"].pop(did, None)
                ns_data["seq"] += 1
                ns_data["head"] = f"{ns_data['seq']:016x}"
                return 200, {"ingested": len(rows), "head": ns_data["head"]}

            if rec["method"] == "POST" and action == "query":
                text = body.get("text")
                query_vec = body.get("vector")
                top_k = body.get("top_k", 10)
                filter_cat = body.get("filter_category")

                candidates: List[Tuple[float, Dict[str, Any]]] = []
                for doc in ns_data["docs"].values():
                    if filter_cat is not None and doc.get("category") != filter_cat:
                        continue

                    score = 0.0
                    matched = False

                    # Text matching simulation (substring / lexical)
                    if text is not None:
                        doc_text = doc.get("text", "")
                        if text in doc_text:
                            score += 1.0 + (len(text) / (len(doc_text) + 1.0))
                            matched = True
                        elif any(token in doc_text for token in text.split()):
                            score += 0.5
                            matched = True

                    # Vector cosine similarity
                    if query_vec is not None and "vector" in doc:
                        dvec = doc["vector"]
                        dot = sum(a * b for a, b in zip(query_vec, dvec))
                        norm_q = math.sqrt(sum(a * a for a in query_vec)) or 1.0
                        norm_d = math.sqrt(sum(b * b for b in dvec)) or 1.0
                        sim = dot / (norm_q * norm_d)
                        score += max(0.0, sim)
                        matched = True

                    if matched or (text is None and query_vec is None):
                        candidates.append((score, doc))

                candidates.sort(key=lambda x: x[0], reverse=True)
                top_hits = candidates[:top_k]

                result_rows = []
                for sc, doc in top_hits:
                    row_dict = {
                        "id": doc["id"],
                        "score": round(sc, 4),
                        "text": doc.get("text", ""),
                        "category": doc.get("category", ""),
                        "ts": doc.get("ts", 0),
                        "public": doc.get("public", True),
                    }
                    result_rows.append(row_dict)

                return 200, {"rows": result_rows, "count": len(result_rows)}

            if rec["method"] == "GET" and action == "health":
                return 200, {
                    "ns": ns,
                    "num_docs": len(ns_data["docs"]),
                    "head": ns_data["head"],
                    "fts_tokenizer": ns_data["tokenizer"],
                }

        return 404, {"error": f"no route for {rec['method']} {rec['path']}"}

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class SingleNodeLocalWorkflowTestCase(unittest.TestCase):
    """End-to-end test case for single-node local workflow."""

    def setUp(self):
        remote_endpoint = os.environ.get("TURBOFISH_ENDPOINT")
        if remote_endpoint:
            self.server = None
            self.endpoint = remote_endpoint.rstrip("/")
        else:
            self.server = StatefulLocalServer()
            self.endpoint = self.server.endpoint
        self.client = TurboFishClient(self.endpoint, timeout=10)
        self.ns = f"local_wf_{os.getpid()}"

    def tearDown(self):
        if self.server is not None:
            self.server.close()

    def test_complete_single_node_lifecycle(self):
        # 1. Namespace Creation
        create_res = self.client.create_namespace(self.ns, fts_tokenizer="word")
        self.assertTrue(create_res.get("ok"))
        self.assertEqual(create_res.get("ns"), self.ns)

        # 2. Batch Upsert Documents (with enriched attributes)
        docs = [
            {
                "id": 101,
                "text": "Vector database written in MoonBit with zero LIST requests",
                "vector": [1.0, 0.0, 0.0, 0.0],
                "category": "database",
                "ts": 1710000000,
                "public": True,
            },
            {
                "id": 102,
                "text": "Compact single-file layout with SPNDFOOT footer and trailer",
                "vector": [0.8, 0.6, 0.0, 0.0],
                "category": "format",
                "ts": 1710000100,
                "public": True,
            },
            {
                "id": 103,
                "text": "Cursor and Notion small mutation workload on object storage",
                "vector": [0.0, 1.0, 0.0, 0.0],
                "category": "workload",
                "ts": 1710000200,
                "public": False,
            },
            {
                "id": 104,
                "text": "Roaring bitmap tombstones for fast soft delete and compaction",
                "vector": [0.0, 0.7, 0.7, 0.0],
                "category": "database",
                "ts": 1710000300,
                "public": True,
            },
        ]
        # Ingest in chunks of 2 to exercise batching logic
        upsert_res = self.client.batch_upsert(self.ns, docs, batch_size=2)
        self.assertEqual(upsert_res["ingested"], 4)
        self.assertEqual(upsert_res["batches"], 2)
        self.assertTrue(upsert_res["head"])

        # Health check verifies num_docs
        h1 = self.client.health(self.ns)
        self.assertEqual(h1["num_docs"], 4)

        # 3. BM25 / Text Query & Enriched Attributes
        q_text = self.client.query(self.ns, text="MoonBit", top_k=5)
        self.assertGreaterEqual(q_text["count"], 1)
        hit_101 = next((r for r in q_text["rows"] if r["id"] == 101), None)
        self.assertIsNotNone(hit_101)
        self.assertIn("MoonBit", hit_101["text"])
        self.assertEqual(hit_101["category"], "database")
        self.assertEqual(hit_101["ts"], 1710000000)
        self.assertTrue(hit_101["public"])

        # 4. Vector Query
        q_vec = self.client.query(self.ns, vector=[1.0, 0.0, 0.0, 0.0], top_k=2)
        self.assertGreaterEqual(len(q_vec["rows"]), 1)
        self.assertEqual(q_vec["rows"][0]["id"], 101)
        self.assertIn("MoonBit", q_vec["rows"][0]["text"])

        # 5. Hybrid Search with Attribute Projection
        q_hybrid = self.client.hybrid_search(
            self.ns,
            text="database",
            vector=[0.0, 0.7, 0.7, 0.0],
            top_k=2,
            attributes=["text", "category"],
        )
        self.assertGreaterEqual(len(q_hybrid["rows"]), 1)
        for row in q_hybrid["rows"]:
            self.assertIn("id", row)
            self.assertIn("score", row)
            self.assertIn("text", row)
            self.assertIn("category", row)
            self.assertNotIn("ts", row)
            self.assertNotIn("public", row)

        # 6. Document Mutation / Update (Upsert id 103)
        updated_103 = [
            {
                "id": 103,
                "text": "Updated Cursor and Notion mutation workload",
                "vector": [0.0, 1.0, 0.0, 0.0],
                "category": "workload",
                "ts": 1710000999,
                "public": True,
            }
        ]
        self.client.upsert(self.ns, updated_103)
        q_updated = self.client.query(self.ns, text="Updated", top_k=1)
        self.assertEqual(len(q_updated["rows"]), 1)
        self.assertEqual(q_updated["rows"][0]["id"], 103)
        self.assertEqual(q_updated["rows"][0]["text"], "Updated Cursor and Notion mutation workload")

        # 7. Batch Delete
        del_res = self.client.batch_delete(self.ns, [101, 102], batch_size=1)
        self.assertEqual(del_res["deleted"], 2)
        self.assertEqual(del_res["batches"], 2)

        # Health reflects reduced doc count
        h2 = self.client.health(self.ns)
        self.assertEqual(h2["num_docs"], 2)

        # Deleted docs no longer hit in queries
        q_deleted = self.client.query(self.ns, text="MoonBit")
        deleted_ids = [r["id"] for r in q_deleted["rows"]]
        self.assertNotIn(101, deleted_ids)


if __name__ == "__main__":
    unittest.main()
