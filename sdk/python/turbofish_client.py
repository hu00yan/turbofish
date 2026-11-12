"""turbofish HTTP API Python client matching Turbopuffer semantics.

Pure standard library (urllib.request + json), no third-party dependencies.

Contract (JSON, no auth):
    POST {endpoint}/v1/namespaces/{ns}/create  {"fts_tokenizer": "word|smartcn|kuromoji|nori"}?
        -> {"ok": true, "ns": "..."}
    POST {endpoint}/v1/namespaces/{ns}/write   {"rows": [...], "deletes": [...]}?
        -> {"ingested": <n>, "head": "..."}
    POST {endpoint}/v1/namespaces/{ns}/query   {"text"?, "vector"?, "top_k"?, "nprobe"?, "filter_category"?, "attributes"?}
        -> {"rows": [{"id", "score", "text", "category", "ts", "public"}...], "count": <n>}
    GET  {endpoint}/v1/namespaces/{ns}/health
        -> {"ns": "...", "num_docs": <n>, "head": "...", "fts_tokenizer": "..."}

A write row is ``{"id": <uint64>, "text": str, "vector": [f32...],
"category": str, "ts": <int64>, "public": bool}``.  Fields other than ``id``
are passed through verbatim; the server validates them.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Dict, Mapping, Optional, Sequence
from urllib.parse import quote

__all__ = ["TurboFishClient", "TurboFishError"]
__version__ = "0.1.0"


class TurboFishError(Exception):
    """Raised for non-2xx responses, transport failures, or malformed replies.

    Attributes:
        status: HTTP status code, or ``None`` when no response was received
            (connection failure, timeout, invalid reply).
        body: Raw response body text, or ``None`` when there is none.
    """

    def __init__(
        self,
        message: str,
        status: Optional[int] = None,
        body: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


class TurboFishClient:
    """Minimal synchronous client for the turbofish HTTP API v0."""

    def __init__(self, endpoint: str, timeout: float = 30) -> None:
        """Create a client.

        Args:
            endpoint: Base URL, e.g. ``http://127.0.0.1:8080``. A trailing
                slash is tolerated.
            timeout: Per-request timeout in seconds (default 30).
        """
        if not endpoint:
            raise ValueError("endpoint must be a non-empty URL")
        self.endpoint = endpoint.rstrip("/")
        self.timeout = timeout

    # ------------------------------------------------------------------ #
    # Public API                                                          #
    # ------------------------------------------------------------------ #

    def create_namespace(self, ns: str, fts_tokenizer: Optional[str] = None) -> Dict[str, Any]:
        """Create a namespace. Returns ``{"ok": true, "ns": ...}``.

        ``fts_tokenizer`` is one of ``word|smartcn|kuromoji|nori``; omit it to
        let the server pick its default.
        """
        payload: Dict[str, Any] = {}
        if fts_tokenizer is not None:
            payload["fts_tokenizer"] = fts_tokenizer
        return self._request("POST", self._url(ns, "create"), payload)

    def write(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        deletes: Optional[Sequence[int]] = None,
    ) -> Dict[str, Any]:
        """Write rows and/or delete ids. Returns ``{"ingested": n, "head": ...}``.

        Each row: ``{"id": uint64, "text": str, "vector": [f32...],
        "category": str, "ts": int64, "public": bool}``.
        """
        if rows is None:
            raise ValueError("rows is required (pass an empty list to only delete)")
        payload: Dict[str, Any] = {"rows": [dict(row) for row in rows]}
        if deletes is not None:
            payload["deletes"] = list(deletes)
        return self._request("POST", self._url(ns, "write"), payload)

    def batch_upsert(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        batch_size: int = 1000,
    ) -> Dict[str, Any]:
        """Upsert documents in batches of ``batch_size``.

        Splits ``rows`` into chunks of at most ``batch_size`` and executes
        sequential ``write`` calls.

        Returns ``{"ingested": total_ingested, "head": last_head, "batches": num_batches}``.
        """
        if rows is None:
            raise ValueError("rows is required")
        if batch_size <= 0:
            raise ValueError("batch_size must be positive")
        rows_list = list(rows)
        if not rows_list:
            return {"ingested": 0, "head": "", "batches": 0}
        total_ingested = 0
        last_head = ""
        batches = 0
        for i in range(0, len(rows_list), batch_size):
            chunk = rows_list[i : i + batch_size]
            res = self.write(ns, rows=chunk)
            total_ingested += res.get("ingested", len(chunk))
            last_head = res.get("head", "")
            batches += 1
        return {"ingested": total_ingested, "head": last_head, "batches": batches}

    def upsert(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        batch_size: int = 1000,
    ) -> Dict[str, Any]:
        """Convenience alias for ``batch_upsert``."""
        return self.batch_upsert(ns, rows, batch_size=batch_size)

    def batch_delete(
        self,
        ns: str,
        ids: Sequence[int],
        batch_size: int = 1000,
    ) -> Dict[str, Any]:
        """Delete document IDs in batches of ``batch_size``.

        Splits ``ids`` into chunks of at most ``batch_size`` and executes
        sequential ``write`` calls with ``rows=[]`` and ``deletes=chunk``.

        Returns ``{"deleted": total_deleted, "head": last_head, "batches": num_batches}``.
        """
        if ids is None:
            raise ValueError("ids is required")
        if batch_size <= 0:
            raise ValueError("batch_size must be positive")
        id_list = list(ids)
        if not id_list:
            return {"deleted": 0, "head": "", "batches": 0}
        total_deleted = 0
        last_head = ""
        batches = 0
        for i in range(0, len(id_list), batch_size):
            chunk = id_list[i : i + batch_size]
            res = self.write(ns, rows=[], deletes=chunk)
            total_deleted += len(chunk)
            last_head = res.get("head", "")
            batches += 1
        return {"deleted": total_deleted, "head": last_head, "batches": batches}

    def delete(
        self,
        ns: str,
        ids: Sequence[int],
        batch_size: int = 1000,
    ) -> Dict[str, Any]:
        """Convenience alias for ``batch_delete``."""
        return self.batch_delete(ns, ids, batch_size=batch_size)

    def query(
        self,
        ns: str,
        text: Optional[str] = None,
        vector: Optional[Sequence[float]] = None,
        top_k: int = 10,
        nprobe: Optional[int] = None,
        filter_category: Optional[str] = None,
        attributes: Optional[Sequence[str]] = None,
    ) -> Dict[str, Any]:
        """Query by FTS ``text`` and/or ``vector``. Returns ``{"rows": [...], "count": n}``.

        Enriched rows include document attributes: ``id``, ``score``, ``text``,
        ``category``, ``ts``, ``public``.
        If ``attributes`` is provided, rows are projected to include only the
        specified attribute names (plus ``id`` and ``score``).
        """
        payload: Dict[str, Any] = {"top_k": top_k}
        if text is not None:
            payload["text"] = text
        if vector is not None:
            payload["vector"] = [float(v) for v in vector]
        if nprobe is not None:
            payload["nprobe"] = nprobe
        if filter_category is not None:
            payload["filter_category"] = filter_category
        if attributes is not None:
            payload["attributes"] = list(attributes)
        res = self._request("POST", self._url(ns, "query"), payload)
        if attributes is not None and "rows" in res and isinstance(res["rows"], list):
            attr_set = set(attributes) | {"id", "score"}
            projected_rows = []
            for r in res["rows"]:
                if isinstance(r, dict):
                    projected_rows.append({k: v for k, v in r.items() if k in attr_set})
                else:
                    projected_rows.append(r)
            res["rows"] = projected_rows
        return res

    def hybrid_search(
        self,
        ns: str,
        text: str,
        vector: Sequence[float],
        top_k: int = 10,
        nprobe: Optional[int] = None,
        filter_category: Optional[str] = None,
        attributes: Optional[Sequence[str]] = None,
    ) -> Dict[str, Any]:
        """Perform hybrid BM25 full-text + vector search with optional attribute projection.

        Combines lexical relevance and vector cosine similarity. Returns
        ``{"rows": [...], "count": n}`` where rows contain enriched document
        attributes projected according to ``attributes``.
        """
        if not text and not vector:
            raise ValueError("hybrid_search requires at least text or vector")
        return self.query(
            ns=ns,
            text=text,
            vector=vector,
            top_k=top_k,
            nprobe=nprobe,
            filter_category=filter_category,
            attributes=attributes,
        )

    def health(self, ns: str) -> Dict[str, Any]:
        """Namespace health. Returns ``{"ns", "num_docs", "head", "fts_tokenizer"}``."""
        return self._request("GET", self._url(ns, "health"))

    # ------------------------------------------------------------------ #
    # Internals                                                           #
    # ------------------------------------------------------------------ #

    def _url(self, ns: str, action: str) -> str:
        return f"{self.endpoint}/v1/namespaces/{quote(str(ns), safe='')}/{action}"

    def _request(self, method: str, url: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            try:
                raw = exc.read()
            except Exception:  # pragma: no cover - body already consumed/absent
                raw = b""
            body = raw.decode("utf-8", "replace")
            raise TurboFishError(
                f"turbofish request failed: HTTP {exc.code} {exc.reason}: {body[:200]}",
                status=exc.code,
                body=body,
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise TurboFishError(
                f"turbofish request failed: {method} {url}: {exc}",
                status=None,
                body=None,
            ) from exc
        return self._decode(raw, status)

    @staticmethod
    def _decode(raw: bytes, status: int) -> Dict[str, Any]:
        text = raw.decode("utf-8", "replace") if raw else ""
        try:
            return json.loads(text)
        except ValueError as exc:
            raise TurboFishError(
                f"turbofish returned invalid JSON (HTTP {status}): {text[:200]!r}",
                status=status,
                body=text,
            ) from exc
