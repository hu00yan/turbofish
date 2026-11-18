"""turbofish HTTP API Python client matching Turbopuffer semantics.

Pure standard library (urllib.request + json), no third-party dependencies.

Contract (JSON):
    POST {endpoint}/v1/namespaces/{ns}/create  {"fts_tokenizer": "word|smartcn|kuromoji|nori"}?,
                                               {"distance_metric": "cosine|euclidean|cosine_distance|euclidean_squared"}?
        -> {"ok": true, "ns": "..."}
    POST {endpoint}/v1/namespaces/{ns}/write   {"rows": [...], "deletes": [...],
                                               "distance_metric": "cosine|euclidean"}?
        -> {"ingested": <n>, "head": "..."}
    POST {endpoint}/v1/namespaces/{ns}/query   {"text"?, "vector"?, "top_k"?, "limit"?, "nprobe"?,
                                               "filter_category"?, "attributes"?, "filter"?,
                                               "offset"?, "aggregations"?, "rank_constant"?,
                                               "fusion"?, "weights"?, "include_attributes"?,
                                               "exclude_attributes"?, "consistency"?}
        -> {"rows": [{"id", "score", "text", "category", "ts", "public"}...], "count": <n>}
           (row ``id`` is a decimal string — u64 全范围精确)
           (aggregations=["Count"] -> {"count": <n>, "rows": []})
           (aggregations=[{"Sum": "field"}] -> {"count": <n>, "aggregations": {"field": {"sum": S}}, "rows": []})
    GET  {endpoint}/v1/namespaces/{ns}/health
        -> {"ns": "...", "num_docs": <n>, "head": "...", "fts_tokenizer": "..."}
    POST {endpoint}/v1/namespaces/{ns}/delete_by_filter {"filter": [...]}
        -> {"deleted": <n>}
    POST {endpoint}/v1/namespaces/{ns}/copy   {"destination": "dest_ns"}
        -> {"ok": true}
    POST {endpoint}/v1/namespaces/{ns}/branch {"destination": "dest_ns"}
        -> {"ok": true}

A write row is ``{"id": <uint64 或十进制字符串>, "text": str, "vector": [f32...],
"category": str, "ts": <int64>, "public": bool}``.  Fields other than ``id``
are passed through verbatim; the server validates them.  ``id`` 以字符串形式
可承载 u64 全范围；number 形式仅接受 ≤ 2^53 的整数（超出报错，不静默截断）。

Authentication: if ``api_key`` is supplied, every request carries
``Authorization: Bearer <key>``.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Dict, Mapping, Optional, Sequence
from urllib.parse import quote

__all__ = ["TurboFishClient", "TurboFishError"]
__version__ = "0.2.0"


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

    def __init__(self, endpoint: str, timeout: float = 30, api_key: Optional[str] = None) -> None:
        """Create a client.

        Args:
            endpoint: Base URL, e.g. ``http://127.0.0.1:8080``. A trailing
                slash is tolerated.
            timeout: Per-request timeout in seconds (default 30).
            api_key: Optional API key. When provided, every request carries
                ``Authorization: Bearer <api_key>``.
        """
        if not endpoint:
            raise ValueError("endpoint must be a non-empty URL")
        self.endpoint = endpoint.rstrip("/")
        self.timeout = timeout
        self.api_key = api_key

    # ------------------------------------------------------------------ #
    # Public API                                                          #
    # ------------------------------------------------------------------ #

    def create_namespace(
        self,
        ns: str,
        fts_tokenizer: Optional[str] = None,
        distance_metric: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Create a namespace. Returns ``{"ok": true, "ns": ...}``.

        ``fts_tokenizer`` is one of ``word|smartcn|kuromoji|nori``; omit it to
        let the server pick its default. ``distance_metric`` is one of
        ``cosine|euclidean|cosine_distance|euclidean_squared``; omit it to let
        the server pick its default.
        """
        payload: Dict[str, Any] = {}
        if fts_tokenizer is not None:
            payload["fts_tokenizer"] = fts_tokenizer
        if distance_metric is not None:
            payload["distance_metric"] = distance_metric
        return self._request("POST", self._url(ns, "create"), payload)

    def write(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        deletes: Optional[Sequence[int]] = None,
        distance_metric: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Write rows and/or delete ids. Returns ``{"ingested": n, "head": ...}``.

        Each row: ``{"id": uint64, "text": str, "vector": [f32...],
        "category": str, "ts": int64, "public": bool}``.
        ``distance_metric`` (\"cosine\" | \"euclidean\") is sent at the top level
        of the write payload; rows themselves never carry it.
        """
        if rows is None:
            raise ValueError("rows is required (pass an empty list to only delete)")
        payload: Dict[str, Any] = {"rows": [dict(row) for row in rows]}
        if deletes is not None:
            payload["deletes"] = list(deletes)
        if distance_metric is not None:
            payload["distance_metric"] = distance_metric
        return self._request("POST", self._url(ns, "write"), payload)

    def batch_upsert(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        batch_size: int = 1000,
        distance_metric: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Upsert documents in batches of ``batch_size``.

        Splits ``rows`` into chunks of at most ``batch_size`` and executes
        sequential ``write`` calls. ``distance_metric`` (\"cosine\" |
        \"euclidean\") is forwarded to every ``write`` call.

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
            res = self.write(ns, rows=chunk, distance_metric=distance_metric)
            total_ingested += res.get("ingested", len(chunk))
            last_head = res.get("head", "")
            batches += 1
        return {"ingested": total_ingested, "head": last_head, "batches": batches}

    def upsert(
        self,
        ns: str,
        rows: Sequence[Mapping[str, Any]],
        batch_size: int = 1000,
        distance_metric: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Convenience alias for ``batch_upsert``."""
        return self.batch_upsert(ns, rows, batch_size=batch_size, distance_metric=distance_metric)

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

    def delete_by_filter(
        self,
        ns: str,
        filter: Sequence[Any],
    ) -> Dict[str, Any]:
        """Delete all documents matching ``filter`` via a server-side filter delete.

        Sends ``POST /v1/namespaces/{ns}/delete_by_filter`` with body
        ``{"filter": filter}``.  The server returns ``{"deleted": <count>}``.
        """
        payload: Dict[str, Any] = {"filter": filter}
        return self._request("POST", self._url(ns, "delete_by_filter"), payload)

    def copy_namespace(self, source_ns: str, dest_ns: str) -> Dict[str, Any]:
        """Copy ``source_ns`` to ``dest_ns`` (full copy, independent data).

        Sends ``POST /v1/namespaces/{source_ns}/copy`` with body
        ``{"destination": dest_ns}``.  Returns the server reply.
        """
        payload: Dict[str, Any] = {"destination": dest_ns}
        return self._request("POST", self._url(source_ns, "copy"), payload)

    def branch_namespace(self, source_ns: str, dest_ns: str) -> Dict[str, Any]:
        """Branch ``source_ns`` to ``dest_ns`` (copy-on-write branch).

        Sends ``POST /v1/namespaces/{source_ns}/branch`` with body
        ``{"destination": dest_ns}``.  Returns the server reply.
        """
        payload: Dict[str, Any] = {"destination": dest_ns}
        return self._request("POST", self._url(source_ns, "branch"), payload)

    def patch_rows(
        self,
        ns: str,
        patches: Sequence[Mapping[str, Any]],
    ) -> Dict[str, Any]:
        """Apply partial attribute/field updates to documents in ``ns``.

        Sends ``POST /v1/namespaces/{ns}/patch`` with body
        ``{"patches": [dict(p) for p in patches]}``.
        Each patch must contain ``"id": <uint64>`` and optional field updates
        such as ``text``, ``category``, ``ts``, ``public``.
        Returns ``{"patched": count, "head": manifest_id}``.
        """
        if patches is None:
            raise ValueError("patches is required")
        payload: Dict[str, Any] = {"patches": [dict(p) for p in patches]}
        return self._request("POST", self._url(ns, "patch"), payload)

    def query(
        self,
        ns: str,
        text: Optional[str] = None,
        vector: Optional[Sequence[float]] = None,
        top_k: int = 10,
        nprobe: Optional[int] = None,
        filter_category: Optional[str] = None,
        attributes: Optional[Sequence[str]] = None,
        filter: Optional[Sequence[Any]] = None,
        offset: Optional[int] = None,
        aggregations: Optional[Sequence[Any]] = None,
        rank_constant: Optional[float] = None,
        fusion: Optional[str] = None,
        weights: Optional[Mapping[str, float]] = None,
        include_attributes: Optional[Sequence[str]] = None,
        exclude_attributes: Optional[Sequence[str]] = None,
        consistency: Optional[str] = None,
        limit: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Query by FTS ``text`` and/or ``vector``. Returns ``{"rows": [...], "count": n}``.

        Enriched rows include document attributes: ``id``, ``score``, ``text``,
        ``category``, ``ts``, ``public``.
        If ``attributes`` is provided, rows are projected to include only the
        specified attribute names (plus ``id`` and ``score``).

        v1 parameters (all optional, backward compatible):

        - ``filter``: a pre-built turbopuffer filter expression, passed
          through verbatim. Leaf ``["attr", "Eq", value]`` with op in
          ``Eq|NotEq|In|NotIn|Lt|Lte|Gt|Gte|Glob``, two-element sugar
          ``["attr", value]`` (equals ``Eq``), and combinators
          ``["And", [...]]`` / ``["Or", [...]]`` / ``["Not", filter]``.
          Values are numbers, strings or booleans; ``In`` takes an array value.
        - ``offset``: skip the first ``offset`` results.
        - ``limit``: alias for ``top_k`` (sent as ``"limit"`` in the payload).
        - ``aggregations``: e.g. ``["Count"]`` or ``[{"Sum": "ts"}]``; the
          server replies with ``{"count": N, "aggregations": {...}, "rows": []}``.
        - ``rank_constant``, ``fusion``, ``weights``: hybrid-ranking controls;
          only effective when both ``text`` and ``vector`` are given.
          ``weights`` is a dict like ``{"bm25": 1.0, "vector": 1.0}`` and is
          passed through verbatim.
        - ``include_attributes`` / ``exclude_attributes``: server-side row
          attribute projection.
        - ``consistency``: ``"strong" | "eventual"``.
        """
        payload: Dict[str, Any] = {"top_k": top_k}
        if limit is not None:
            payload["limit"] = limit
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
        if filter is not None:
            payload["filter"] = filter
        if offset is not None:
            payload["offset"] = offset
        if aggregations is not None:
            payload["aggregations"] = list(aggregations)
        if rank_constant is not None:
            payload["rank_constant"] = rank_constant
        if fusion is not None:
            payload["fusion"] = fusion
        if weights is not None:
            payload["weights"] = dict(weights)
        if include_attributes is not None:
            payload["include_attributes"] = list(include_attributes)
        if exclude_attributes is not None:
            payload["exclude_attributes"] = list(exclude_attributes)
        if consistency is not None:
            payload["consistency"] = consistency
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

    def count(
        self,
        ns: str,
        filter: Optional[Sequence[Any]] = None,
        consistency: Optional[str] = None,
    ) -> int:
        """Count documents matching ``filter`` via the ``Count`` aggregation.

        Sends ``aggregations=["Count"]`` under the hood; the server replies
        ``{"count": N, "rows": []}`` and the count is returned as an ``int``.
        """
        res = self.query(ns, filter=filter, consistency=consistency, aggregations=["Count"])
        return res["count"]

    def hybrid_search(
        self,
        ns: str,
        text: str,
        vector: Sequence[float],
        top_k: int = 10,
        nprobe: Optional[int] = None,
        filter_category: Optional[str] = None,
        attributes: Optional[Sequence[str]] = None,
        filter: Optional[Sequence[Any]] = None,
        rank_constant: Optional[float] = None,
        fusion: Optional[str] = None,
        weights: Optional[Mapping[str, float]] = None,
    ) -> Dict[str, Any]:
        """Perform hybrid BM25 full-text + vector search with optional attribute projection.

        Combines lexical relevance and vector cosine similarity. Returns
        ``{"rows": [...], "count": n}`` where rows contain enriched document
        attributes projected according to ``attributes``. ``rank_constant``,
        ``fusion`` and ``weights`` only take effect for hybrid (text+vector)
        queries; ``filter`` accepts a pre-built turbopuffer filter expression
        passed through verbatim (see :meth:`query`).
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
            filter=filter,
            rank_constant=rank_constant,
            fusion=fusion,
            weights=weights,
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
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
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
