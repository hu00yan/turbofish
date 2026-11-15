"""Persistent-connection clients for the Turbofish / Qdrant comparison.

Both wrappers keep a single keep-alive connection and return ``(ids, seconds)``
per query so the caller can time exactly one round trip (no TCP/TLS setup,
no client-side JSON decoding ambiguity).

Only the standard library is used for Turbofish. Qdrant is accessed through
``qdrant_client`` (httpx, HTTP keep-alive) because that is the supported client;
its transport is verified to reuse connections by the runner's warm-up.
"""

from __future__ import annotations

import http.client
import json
import time
from typing import Any, Dict, Iterable, List, Sequence, Tuple
from urllib.parse import quote

import numpy as np


class TurbofishHTTP:
    """Minimal HTTP/1.1 keep-alive client for the Turbofish v1 API."""

    def __init__(self, host: str = "127.0.0.1", port: int = 8081, timeout: float = 300.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._conn: http.client.HTTPConnection | None = None
        self._connect()

    # -- connection management -------------------------------------------
    def _connect(self) -> None:
        self._conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        self._conn.connect()

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            finally:
                self._conn = None

    def reconnect(self) -> None:
        self.close()
        self._connect()

    # -- transport -------------------------------------------------------
    def _post(self, path: str, payload: Dict[str, Any]) -> Tuple[Dict[str, Any], float]:
        body = json.dumps(payload, separators=(",", ":"))
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self._conn is None or self._conn.sock is None:
            self._connect()
        t0 = time.perf_counter()
        try:
            self._conn.request("POST", path, body=body, headers=headers)
            resp = self._conn.getresponse()
            raw = resp.read()
            status = resp.status
        except (http.client.HTTPException, OSError):
            # One transparent reconnect per request (connection was closed by
            # the server or by an idle timeout). The retry is timed from the
            # fresh request so TCP setup is not billed to the query.
            self.reconnect()
            t0 = time.perf_counter()
            self._conn.request("POST", path, body=body, headers=headers)
            resp = self._conn.getresponse()
            raw = resp.read()
            status = resp.status
        dt = time.perf_counter() - t0
        if status >= 400:
            raise RuntimeError(f"turbofish HTTP {status} on {path}: {raw[:300]!r}")
        return json.loads(raw), dt

    def _get(self, path: str) -> Tuple[Dict[str, Any], float]:
        if self._conn is None or self._conn.sock is None:
            self._connect()
        t0 = time.perf_counter()
        self._conn.request("GET", path, headers={"Accept": "application/json"})
        resp = self._conn.getresponse()
        raw = resp.read()
        dt = time.perf_counter() - t0
        if resp.status >= 400:
            raise RuntimeError(f"turbofish HTTP {resp.status} on {path}: {raw[:300]!r}")
        return json.loads(raw), dt

    # -- API -------------------------------------------------------------
    @staticmethod
    def _ns(ns: str) -> str:
        return quote(ns, safe="")

    def create(self, ns: str, distance_metric: str = "cosine") -> None:
        payload: Dict[str, Any] = {}
        if distance_metric is not None:
            payload["distance_metric"] = distance_metric
        self._post(f"/v1/namespaces/{self._ns(ns)}/create", payload)

    def write(self, ns: str, rows: Sequence[Dict[str, Any]]) -> Tuple[Dict[str, Any], float]:
        return self._post(f"/v1/namespaces/{self._ns(ns)}/write", {"rows": list(rows)})

    def query(self, ns: str, vector: Sequence[float], top_k: int, nprobe: int) -> Tuple[List[int], float]:
        payload = {
            "vector": [float(v) for v in vector],
            "top_k": int(top_k),
            "nprobe": int(nprobe),
            "include_attributes": [],  # id + score only, like Qdrant with_payload=False
        }
        res, dt = self._post(f"/v1/namespaces/{self._ns(ns)}/query", payload)
        ids = [int(r["id"]) for r in res["rows"]]
        return ids, dt

    def health(self, ns: str) -> Dict[str, Any]:
        res, _ = self._get(f"/v1/namespaces/{self._ns(ns)}/health")
        return res

    def compact(self, ns: str) -> float:
        _, dt = self._post(f"/v1/namespaces/{self._ns(ns)}/compact", {})
        return dt


class QdrantHTTP:
    """Thin wrapper around qdrant_client with per-query timing."""

    def __init__(self, host: str = "127.0.0.1", port: int = 6333, collection: str = "perf", timeout: float = 300.0):
        from qdrant_client import QdrantClient  # imported lazily

        self.collection = collection
        self._client = QdrantClient(host=host, port=port, timeout=int(timeout))
        self._SearchParams = None

    # -- collection management -------------------------------------------
    def create(self, dim: int, on_disk_payload: bool = True) -> None:
        from qdrant_client.http import models as qm

        self._client.create_collection(
            collection_name=self.collection,
            vectors_config=qm.VectorParams(size=int(dim), distance=qm.Distance.COSINE),
            # Qdrant's indexing_threshold is the maximum plain-index size in kB:
            # 0 disables vector indexing entirely, and the 20,000 kB default left a
            # sub-threshold segment brute-forced at 50k docs. 1 kB indexes every
            # non-empty segment. default_segment_number=1 gives one comparable
            # segment; all HNSW parameters stay at their defaults.
            optimizers_config=qm.OptimizersConfigDiff(
                indexing_threshold=1, default_segment_number=1
            ),
            on_disk_payload=on_disk_payload,
        )

    def delete(self) -> None:
        self._client.delete_collection(self.collection)

    def reconnect(self) -> None:
        """Drop the pooled HTTP connections and open a fresh client."""
        from qdrant_client import QdrantClient

        try:
            self._client.close()
        except Exception:
            pass
        self._client = QdrantClient(host="127.0.0.1", port=6333, timeout=300)

    def upsert(self, ids: Sequence[int], vectors: np.ndarray, payloads: Sequence[Dict[str, Any]]) -> float:
        from qdrant_client.http import models as qm

        points = [
            qm.PointStruct(id=int(pid), vector=vectors[i].tolist(), payload=dict(payloads[i]))
            for i, pid in enumerate(ids)
        ]
        t0 = time.perf_counter()
        self._client.upsert(collection_name=self.collection, points=points, wait=True)
        return time.perf_counter() - t0

    def wait_ready(self, expected_points: int, timeout: float = 1800.0) -> float:
        t0 = time.perf_counter()
        deadline = t0 + timeout
        last = None
        while time.perf_counter() < deadline:
            info = self._client.get_collection(self.collection)
            last = info
            status = str(getattr(info, "status", ""))
            points = int(getattr(info, "points_count", 0) or 0)
            indexed = getattr(info, "indexed_vectors_count", None)
            indexed_n = int(indexed or 0)
            # Require the HNSW index to cover every point, not merely "green":
            # Qdrant can report green while vectors are still plain-indexed.
            if (
                points >= expected_points
                and indexed_n >= expected_points
                and "green" in status.lower()
            ):
                return time.perf_counter() - t0
            time.sleep(1.0)
        raise TimeoutError(f"qdrant collection not green after {timeout}s: {last}")

    def info(self) -> Dict[str, Any]:
        info = self._client.get_collection(self.collection)
        out: Dict[str, Any] = {}
        for key in (
            "status",
            "points_count",
            "indexed_vectors_count",
            "segments_count",
            "payload_schema",
            "config",
        ):
            try:
                val = getattr(info, key)
                out[key] = val.model_dump() if hasattr(val, "model_dump") else val
            except Exception:  # pragma: no cover - version dependent
                pass
        return out

    # -- query -----------------------------------------------------------
    def query(self, vector: Sequence[float], top_k: int, hnsw_ef: int) -> Tuple[List[int], float]:
        from qdrant_client.http import models as qm

        params = qm.SearchParams(hnsw_ef=int(hnsw_ef), exact=False)
        t0 = time.perf_counter()
        res = self._client.query_points(
            collection_name=self.collection,
            query=[float(v) for v in vector],
            limit=int(top_k),
            search_params=params,
            with_payload=False,
            with_vectors=False,
        )
        dt = time.perf_counter() - t0
        ids = [int(p.id) for p in res.points]
        return ids, dt


def run_timed(queries: Iterable[Sequence[float]], fn) -> Tuple[List[float], List[List[int]]]:
    """Run ``fn(query_vector) -> (ids, seconds)`` over queries, collecting both."""
    latencies: List[float] = []
    results: List[List[int]] = []
    for q in queries:
        ids, dt = fn(q)
        latencies.append(dt)
        results.append(ids)
    return latencies, results
