"""Unit tests for the turbofish Python client (mock HTTP, stdlib only).

Mock HTTP: a local http.server on an ephemeral port records each request
(method / path / JSON body / headers) and replies with canned payloads.

Run: python3 -m unittest discover sdk/python
"""

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from turbofish_client import TurboFishClient, TurboFishError

ROWS = [
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
]


class MockServer:
    """Tiny configurable HTTP server that records requests."""

    def __init__(self):
        self.requests = []
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
                outer.requests.append(rec)
                status, payload = outer.respond(rec)
                if isinstance(payload, str):  # escape hatch for non-JSON replies
                    data = payload.encode("utf-8")
                    content_type = "text/plain"
                else:
                    data = json.dumps(payload).encode("utf-8")
                    content_type = "application/json"
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = _handle
            do_POST = _handle

            def log_message(self, fmt, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.respond = self.default_respond
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def default_respond(self, rec):
        parts = rec["path"].split("/")  # ['', 'v1', 'namespaces', ns, action]
        if len(parts) >= 5 and parts[1] == "v1" and parts[2] == "namespaces":
            ns, action = parts[3], parts[4]
            body = json.loads(rec["body"]) if rec["body"] else {}
            if rec["method"] == "POST" and action == "create":
                return 200, {"ok": True, "ns": ns}
            if rec["method"] == "POST" and action == "write":
                return 200, {"ingested": len(body.get("rows", [])), "head": "feedface"}
            if rec["method"] == "POST" and action == "query":
                return 200, {
                    "rows": [
                        {
                            "id": 1,
                            "score": 0.5,
                            "text": body.get("text") or "今日は寿司を食べました",
                            "category": "food",
                            "ts": 1700000000,
                            "public": True,
                        }
                    ],
                    "count": 1,
                }
            if rec["method"] == "GET" and action == "health":
                return 200, {"ns": ns, "num_docs": 3, "head": "feedface", "fts_tokenizer": "kuromoji"}
            if rec["method"] == "POST" and action == "delete_by_filter":
                return 200, {"deleted": 5}
            if rec["method"] == "POST" and action == "copy":
                return 200, {"ok": True}
            if rec["method"] == "POST" and action == "branch":
                return 200, {"ok": True}
            if rec["method"] == "POST" and action == "patch":
                return 200, {"patched": len(body.get("patches", [])), "head": "patchhead"}
        return 404, {"error": f"no route for {rec['method']} {rec['path']}"}

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class TurboFishClientTestCase(unittest.TestCase):
    def setUp(self):
        self.server = MockServer()
        self.client = TurboFishClient(self.server.endpoint, timeout=5)

    def tearDown(self):
        self.server.close()

    def last_request(self):
        return self.server.requests[-1]

    # --- create_namespace -------------------------------------------------

    def test_create_namespace_posts_empty_body_by_default(self):
        out = self.client.create_namespace("ns-a")
        self.assertTrue(out["ok"])
        self.assertEqual(out["ns"], "ns-a")
        rec = self.last_request()
        self.assertEqual(rec["method"], "POST")
        self.assertEqual(rec["path"], "/v1/namespaces/ns-a/create")
        self.assertEqual(json.loads(rec["body"]), {})
        self.assertEqual(rec["headers"].get("Content-Type"), "application/json")

    def test_create_namespace_with_tokenizer(self):
        out = self.client.create_namespace("ns-a", fts_tokenizer="kuromoji")
        self.assertTrue(out["ok"])
        self.assertEqual(json.loads(self.last_request()["body"]), {"fts_tokenizer": "kuromoji"})

    # --- write ------------------------------------------------------------

    def test_write_sends_rows_and_deletes(self):
        out = self.client.write("ns", ROWS, deletes=[2])
        self.assertEqual(out["ingested"], 2)
        self.assertEqual(out["head"], "feedface")
        rec = self.last_request()
        self.assertEqual(rec["path"], "/v1/namespaces/ns/write")
        body = json.loads(rec["body"])
        self.assertEqual(body["rows"], ROWS)
        self.assertEqual(body["deletes"], [2])

    def test_write_omits_deletes_when_not_given(self):
        self.client.write("ns", ROWS)
        body = json.loads(self.last_request()["body"])
        self.assertNotIn("deletes", body)
        self.assertEqual(body["rows"], ROWS)

    def test_write_requires_rows(self):
        with self.assertRaises(ValueError):
            self.client.write("ns", None)
        self.assertEqual(self.server.requests, [])  # nothing hit the wire

    # --- batch_upsert and upsert ------------------------------------------

    def test_batch_upsert_splits_batches(self):
        rows = [
            {"id": i, "text": f"doc {i}", "vector": [float(i), 0.0, 0.0, 0.0]}
            for i in range(5)
        ]
        res = self.client.batch_upsert("ns", rows, batch_size=2)
        self.assertEqual(res["ingested"], 5)
        self.assertEqual(res["batches"], 3)
        self.assertEqual(len(self.server.requests), 3)
        b0 = json.loads(self.server.requests[0]["body"])
        b1 = json.loads(self.server.requests[1]["body"])
        b2 = json.loads(self.server.requests[2]["body"])
        self.assertEqual(len(b0["rows"]), 2)
        self.assertEqual(len(b1["rows"]), 2)
        self.assertEqual(len(b2["rows"]), 1)

    def test_upsert_alias(self):
        res = self.client.upsert("ns", ROWS)
        self.assertEqual(res["ingested"], 2)
        self.assertEqual(res["batches"], 1)

    # --- batch_delete and delete ------------------------------------------

    def test_batch_delete_splits_batches(self):
        ids = list(range(10))
        res = self.client.batch_delete("ns", ids, batch_size=4)
        self.assertEqual(res["deleted"], 10)
        self.assertEqual(res["batches"], 3)
        self.assertEqual(len(self.server.requests), 3)
        d0 = json.loads(self.server.requests[0]["body"])
        self.assertEqual(d0["rows"], [])
        self.assertEqual(d0["deletes"], [0, 1, 2, 3])

    def test_delete_alias(self):
        res = self.client.delete("ns", [1, 2])
        self.assertEqual(res["deleted"], 2)
        self.assertEqual(res["batches"], 1)

    # --- delete_by_filter -------------------------------------------------

    def test_delete_by_filter_posts_correct_endpoint_and_body(self):
        filt = ["category", "Eq", "clothing"]
        out = self.client.delete_by_filter("ns", filt)
        self.assertEqual(out["deleted"], 5)
        rec = self.last_request()
        self.assertEqual(rec["method"], "POST")
        self.assertEqual(rec["path"], "/v1/namespaces/ns/delete_by_filter")
        body = json.loads(rec["body"])
        self.assertEqual(body["filter"], filt)

    def test_delete_by_filter_glob_expression(self):
        filt = ["category", "Glob", "cloth*"]
        out = self.client.delete_by_filter("my-ns", filt)
        self.assertEqual(out["deleted"], 5)
        rec = self.last_request()
        self.assertEqual(rec["path"], "/v1/namespaces/my-ns/delete_by_filter")
        body = json.loads(rec["body"])
        self.assertEqual(body["filter"], filt)

    # --- copy_namespace ---------------------------------------------------

    def test_copy_namespace_posts_to_copy_endpoint(self):
        out = self.client.copy_namespace("src-ns", "dst-ns")
        self.assertTrue(out["ok"])
        rec = self.last_request()
        self.assertEqual(rec["method"], "POST")
        self.assertEqual(rec["path"], "/v1/namespaces/src-ns/copy")
        body = json.loads(rec["body"])
        self.assertEqual(body["destination"], "dst-ns")

    # --- branch_namespace -------------------------------------------------

    def test_branch_namespace_posts_to_branch_endpoint(self):
        out = self.client.branch_namespace("src-ns", "branch-ns")
        self.assertTrue(out["ok"])
        rec = self.last_request()
        self.assertEqual(rec["method"], "POST")
        self.assertEqual(rec["path"], "/v1/namespaces/src-ns/branch")
        body = json.loads(rec["body"])
        self.assertEqual(body["destination"], "branch-ns")

    # --- patch_rows -------------------------------------------------------

    def test_patch_rows_posts_patches_and_returns_result(self):
        patches = [
            {"id": 1, "category": "updated_cat", "ts": 1700000500},
            {"id": 2, "public": False},
        ]
        out = self.client.patch_rows("ns", patches)
        self.assertEqual(out["patched"], 2)
        self.assertEqual(out["head"], "patchhead")
        rec = self.last_request()
        self.assertEqual(rec["method"], "POST")
        self.assertEqual(rec["path"], "/v1/namespaces/ns/patch")
        body = json.loads(rec["body"])
        self.assertEqual(body["patches"], patches)

    def test_patch_rows_requires_patches(self):
        with self.assertRaises(ValueError):
            self.client.patch_rows("ns", None)

    # --- query ------------------------------------------------------------

    def test_query_returns_enriched_attributes(self):
        res = self.client.query("ns", text="sushi")
        self.assertEqual(res["count"], 1)
        row = res["rows"][0]
        self.assertEqual(row["id"], 1)
        self.assertEqual(row["score"], 0.5)
        self.assertEqual(row["text"], "sushi")
        self.assertEqual(row["category"], "food")
        self.assertEqual(row["ts"], 1700000000)
        self.assertEqual(row["public"], True)

    def test_query_with_attribute_projection(self):
        res = self.client.query("ns", text="sushi", attributes=["text", "category"])
        row = res["rows"][0]
        self.assertEqual(row["id"], 1)
        self.assertEqual(row["score"], 0.5)
        self.assertEqual(row["text"], "sushi")
        self.assertEqual(row["category"], "food")
        self.assertNotIn("ts", row)
        self.assertNotIn("public", row)

    # --- hybrid_search helper ---------------------------------------------

    def test_hybrid_search_helper(self):
        res = self.client.hybrid_search(
            "ns",
            text="sushi",
            vector=[1.0, 0.0, 0.0, 0.0],
            top_k=3,
            attributes=["text"],
        )
        rec = self.last_request()
        body = json.loads(rec["body"])
        self.assertEqual(body["text"], "sushi")
        self.assertEqual(body["vector"], [1.0, 0.0, 0.0, 0.0])
        self.assertEqual(body["top_k"], 3)
        self.assertEqual(body["attributes"], ["text"])
        row = res["rows"][0]
        self.assertEqual(row["id"], 1)
        self.assertEqual(row["text"], "sushi")
        self.assertNotIn("category", row)
        self.assertNotIn("ts", row)

    def test_query_sends_all_set_parameters(self):
        self.client.query("ns", text="sushi", vector=[1, 2, 3, 4], top_k=5, nprobe=2, filter_category="rs")
        rec = self.last_request()
        self.assertEqual(rec["path"], "/v1/namespaces/ns/query")
        self.assertEqual(
            json.loads(rec["body"]),
            {
                "text": "sushi",
                "vector": [1.0, 2.0, 3.0, 4.0],
                "top_k": 5,
                "nprobe": 2,
                "filter_category": "rs",
            },
        )

    def test_query_defaults_and_omission(self):
        self.client.query("ns", text="hi")
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body, {"text": "hi", "top_k": 10})

    def test_query_vector_only(self):
        self.client.query("ns", vector=[0.5, 0.5, 0.0, 0.0], top_k=3)
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body, {"vector": [0.5, 0.5, 0.0, 0.0], "top_k": 3})

    def test_query_limit_parameter_sent(self):
        """limit is forwarded verbatim alongside top_k."""
        self.client.query("ns", text="hello", limit=5)
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["limit"], 5)
        self.assertIn("top_k", body)

    def test_query_aggregations_count(self):
        self.server.respond = lambda rec: (200, {"count": 7, "rows": []})
        self.client.query("ns", aggregations=["Count"])
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["aggregations"], ["Count"])

    def test_query_aggregations_sum(self):
        self.server.respond = lambda rec: (
            200,
            {"count": 2, "aggregations": {"ts": {"sum": 3400000100.0}}, "rows": []},
        )
        res = self.client.query("ns", aggregations=[{"Sum": "ts"}])
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["aggregations"], [{"Sum": "ts"}])
        self.assertIn("aggregations", res)

    def test_query_metric_cosine_distance(self):
        self.client.create_namespace("ns", distance_metric="cosine_distance")
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["distance_metric"], "cosine_distance")

    def test_query_metric_euclidean_squared(self):
        self.client.create_namespace("ns", distance_metric="euclidean_squared")
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["distance_metric"], "euclidean_squared")

    # --- query: new v1 parameters ------------------------------------------

    def test_query_sends_filter_offset_and_fusion_params(self):
        self.client.query(
            "ns",
            text="sushi",
            vector=[1.0, 0.0, 0.0, 0.0],
            filter=["And", [["category", "Eq", "books"], ["Not", ["public", "Eq", False]]]],
            offset=5,
            rank_constant=60,
            fusion="rrf",
            weights={"bm25": 1.0, "vector": 1.0},
            include_attributes=["text", "ts"],
            exclude_attributes=["public"],
            consistency="strong",
        )
        rec = self.last_request()
        self.assertEqual(rec["path"], "/v1/namespaces/ns/query")
        body = json.loads(rec["body"])
        self.assertEqual(
            body["filter"],
            ["And", [["category", "Eq", "books"], ["Not", ["public", "Eq", False]]]],
        )
        self.assertEqual(body["offset"], 5)
        self.assertEqual(body["rank_constant"], 60)
        self.assertEqual(body["fusion"], "rrf")
        self.assertEqual(body["weights"], {"bm25": 1.0, "vector": 1.0})
        self.assertEqual(body["include_attributes"], ["text", "ts"])
        self.assertEqual(body["exclude_attributes"], ["public"])
        self.assertEqual(body["consistency"], "strong")

    def test_count_helper_posts_count_aggregation(self):
        self.server.respond = lambda rec: (200, {"count": 7, "rows": []})
        n = self.client.count(
            "ns",
            filter=["category", "In", ["books", "food"]],
            consistency="eventual",
        )
        self.assertEqual(n, 7)
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["aggregations"], ["Count"])
        self.assertEqual(body["filter"], ["category", "In", ["books", "food"]])
        self.assertEqual(body["consistency"], "eventual")
        self.assertNotIn("text", body)
        self.assertNotIn("vector", body)

    # --- distance_metric on create/write ------------------------------------

    def test_create_and_write_send_distance_metric(self):
        self.client.create_namespace("ns", distance_metric="cosine")
        self.assertEqual(json.loads(self.last_request()["body"]), {"distance_metric": "cosine"})

        self.client.write("ns", ROWS, distance_metric="euclidean")
        body = json.loads(self.last_request()["body"])
        self.assertEqual(body["distance_metric"], "euclidean")
        self.assertEqual(body["rows"], ROWS)

        self.client.upsert("ns", ROWS[:1], batch_size=1, distance_metric="cosine")
        self.assertEqual(json.loads(self.last_request()["body"])["distance_metric"], "cosine")

    # --- health -----------------------------------------------------------

    def test_health_gets_and_parses(self):
        out = self.client.health("ns")
        self.assertEqual(out["ns"], "ns")
        self.assertEqual(out["num_docs"], 3)
        self.assertEqual(out["fts_tokenizer"], "kuromoji")
        rec = self.last_request()
        self.assertEqual(rec["method"], "GET")
        self.assertEqual(rec["path"], "/v1/namespaces/ns/health")
        self.assertEqual(rec["body"], "")

    # --- api_key auth -------------------------------------------------------

    def test_api_key_sends_authorization_header(self):
        client = TurboFishClient(self.server.endpoint, timeout=5, api_key="secret-token")
        client.health("ns")
        rec = self.last_request()
        self.assertEqual(rec["headers"].get("Authorization"), "Bearer secret-token")

    def test_no_api_key_omits_authorization_header(self):
        self.client.health("ns")
        rec = self.last_request()
        self.assertNotIn("Authorization", rec["headers"])

    def test_api_key_sent_on_all_methods(self):
        client = TurboFishClient(self.server.endpoint, timeout=5, api_key="my-key")
        client.create_namespace("ns")
        self.assertEqual(self.last_request()["headers"].get("Authorization"), "Bearer my-key")
        client.write("ns", ROWS)
        self.assertEqual(self.last_request()["headers"].get("Authorization"), "Bearer my-key")
        client.query("ns", text="hello")
        self.assertEqual(self.last_request()["headers"].get("Authorization"), "Bearer my-key")

    # --- errors -----------------------------------------------------------

    def test_http_error_carries_status_and_body(self):
        self.server.respond = lambda rec: (404, {"error": "namespace not found"})
        with self.assertRaises(TurboFishError) as ctx:
            self.client.health("ns")
        self.assertEqual(ctx.exception.status, 404)
        self.assertIn("namespace not found", ctx.exception.body)

    def test_invalid_json_reply_raises(self):
        self.server.respond = lambda rec: (200, "<html>oops</html>")
        with self.assertRaises(TurboFishError) as ctx:
            self.client.health("ns")
        self.assertEqual(ctx.exception.status, 200)
        self.assertIn("oops", ctx.exception.body)

    def test_connection_failure_raises_with_null_status(self):
        client = TurboFishClient("http://127.0.0.1:9", timeout=2)  # discard port
        with self.assertRaises(TurboFishError) as ctx:
            client.health("ns")
        self.assertIsNone(ctx.exception.status)

    # --- URL handling -------------------------------------------------------

    def test_namespace_is_url_quoted(self):
        self.client.create_namespace("a b/c")
        self.assertEqual(self.last_request()["path"], "/v1/namespaces/a%20b%2Fc/create")

    def test_trailing_slash_in_endpoint_is_tolerated(self):
        client = TurboFishClient(self.server.endpoint + "/", timeout=5)
        out = client.health("ns")
        self.assertEqual(out["ns"], "ns")
        self.assertEqual(self.last_request()["path"], "/v1/namespaces/ns/health")


if __name__ == "__main__":
    unittest.main()
