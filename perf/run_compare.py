#!/usr/bin/env python3
"""Fair, reproducible Turbofish-vs-Qdrant vector-search comparison.

Run this *inside* the Linux benchmark VM (it needs the Turbofish release
binary, MinIO, Qdrant and toxiproxy on localhost). It:

  1. generates one deterministic clustered dataset and query set,
  2. computes exact top-10 ground truth with brute-force numpy cosine,
  3. ingests the *same* rows into Turbofish (S3/MinIO, direct :9000 and
     toxiproxy :19000) and into Qdrant (local disk), 1000 rows per request,
  4. tunes nprobe / hnsw_ef to land near the same recall (~0.95),
  5. measures warm latency with persistent HTTP keep-alive connections,
     interleaving the engines across >=3 repetitions,
  6. measures a post-restart "cold process" window,
  7. records RSS, real bucket/collection bytes and real S3 request counts
     (via `mc admin trace`, not packet counts),
  8. writes a machine-readable JSON result file and a summary table.

Nothing in this file modifies the Turbofish source tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from clients import QdrantHTTP, TurbofishHTTP  # noqa: E402

TOP_K = 10
DEFAULT_MC = "/opt/minio/mc"
DEFAULT_QDRANT_BIN = "qdrant"


# --------------------------------------------------------------------------
# small utilities
# --------------------------------------------------------------------------
def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sh(
    cmd: Sequence[str],
    *,
    check: bool = False,
    timeout: Optional[float] = None,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[str] = None,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        list(cmd), check=check, timeout=timeout, env=env, cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def fmt_cmd(cmd: Sequence[str]) -> str:
    return " ".join(str(c) for c in cmd)


def pctl(values: Sequence[float], q: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), q))


def summarize(latencies: Sequence[float], wall: Optional[float] = None) -> Dict[str, Any]:
    a = np.asarray(latencies, dtype=np.float64)
    out: Dict[str, Any] = {
        "count": int(a.size),
        "mean_ms": float(a.mean() * 1e3) if a.size else None,
        "std_ms": float(a.std(ddof=0) * 1e3) if a.size else None,
        "min_ms": float(a.min() * 1e3) if a.size else None,
        "p50_ms": pctl(a, 50) * 1e3 if a.size else None,
        "p95_ms": pctl(a, 95) * 1e3 if a.size else None,
        "p99_ms": pctl(a, 99) * 1e3 if a.size else None,
        "max_ms": float(a.max() * 1e3) if a.size else None,
    }
    if wall is not None and wall > 0:
        out["wall_seconds"] = wall
        out["qps"] = a.size / wall
    return out


def mean_recall(gt: Sequence[Sequence[int]], got: Sequence[Sequence[int]], k: int = TOP_K) -> float:
    if len(gt) == 0:
        return float("nan")
    total = 0
    for g, r in zip(gt, got):
        total += len(set(int(x) for x in g[:k]) & set(int(x) for x in r[:k]))
    return total / (len(gt) * k)


def read_proc_status(pid: int) -> Dict[str, Any]:
    path = Path(f"/proc/{pid}/status")
    out: Dict[str, Any] = {"pid": pid}
    try:
        for line in path.read_text().splitlines():
            if line.startswith("VmRSS:"):
                out["rss_kb"] = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                out["peak_rss_kb"] = int(line.split()[1])
            elif line.startswith("Threads:"):
                out["threads"] = int(line.split()[1])
    except OSError:
        pass
    return out


def pid_by_pgrep(pattern: str) -> Optional[int]:
    res = sh(["pgrep", "-f", pattern])
    if res.returncode == 0:
        pids = [int(x) for x in res.stdout.split() if x.isdigit()]
        if pids:
            return pids[0]
    return None


def pid_by_cmdline(substr: str) -> Optional[int]:
    needle = substr.encode()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmd = (entry / "cmdline").read_bytes()
        except OSError:
            continue
        if needle in cmd:
            return int(entry.name)
    return None


def wait_port(host: str, port: int, timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"{host}:{port} not listening after {timeout}s")


def http_status(url: str, timeout: float = 3.0) -> int:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status
    except Exception as exc:  # pragma: no cover - health probing
        code = getattr(exc, "code", None)
        return int(code) if code else 0


def dir_size_bytes(path: Path) -> Optional[int]:
    if not path.exists():
        return None
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def sha256_file(path: Path) -> Optional[str]:
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


# --------------------------------------------------------------------------
# dataset
# --------------------------------------------------------------------------
def l2_normalize(x: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(x, axis=1, keepdims=True)
    return (x / np.maximum(n, 1e-12)).astype(np.float32)


def exact_ground_truth(
    queries: np.ndarray, docs: np.ndarray, ids: np.ndarray, k: int = TOP_K, chunk: int = 64
) -> np.ndarray:
    """Exact top-k cosine ids, ties broken by ascending id."""
    gt = np.empty((queries.shape[0], k), dtype=np.int64)
    ids_f = ids.astype(np.float64)
    for start in range(0, queries.shape[0], chunk):
        block = queries[start:start + chunk]
        sims = block @ docs.T  # float32 matmul, (chunk, n)
        for row in range(sims.shape[0]):
            s = sims[row]
            order = np.lexsort((ids_f, -s.astype(np.float64)))
            gt[start + row] = ids_f[order[:k]].astype(np.int64)
    return gt


def build_dataset(cfg: argparse.Namespace) -> Dict[str, Any]:
    rng = np.random.default_rng(cfg.seed)
    centers = rng.uniform(-1.0, 1.0, size=(cfg.clusters, cfg.dim)).astype(np.float32)
    cluster_of = rng.integers(0, cfg.clusters, size=cfg.docs)
    noise = rng.uniform(-cfg.noise, cfg.noise, size=(cfg.docs, cfg.dim)).astype(np.float32)
    docs = l2_normalize(centers[cluster_of] + noise)

    n_queries = cfg.queries + cfg.tuning_queries + cfg.cold_queries * cfg.cold_reps
    if n_queries > cfg.docs:
        raise SystemExit("query set larger than dataset; increase --docs")
    query_docs = rng.choice(cfg.docs, size=n_queries, replace=False)
    qnoise = rng.normal(0.0, cfg.qnoise, size=(n_queries, cfg.dim)).astype(np.float32)
    queries = l2_normalize(docs[query_docs] + qnoise)

    ids = np.arange(1, cfg.docs + 1, dtype=np.uint64)
    gt = exact_ground_truth(queries, docs, ids, k=TOP_K)

    texts = [f"w{int(cluster_of[i]):02d} t{i % 997:03d} c{i % 7}" for i in range(cfg.docs)]
    categories = [f"cat{i % 8}" for i in range(cfg.docs)]

    digest = hashlib.sha256()
    digest.update(np.ascontiguousarray(docs).tobytes())
    digest.update(np.ascontiguousarray(queries).tobytes())
    digest.update(np.ascontiguousarray(ids).tobytes())

    return {
        "docs": docs,
        "ids": ids,
        "queries": queries,
        "gt": gt,
        "texts": texts,
        "categories": categories,
        "query_docs": query_docs,
        "sha256": digest.hexdigest(),
    }


# --------------------------------------------------------------------------
# S3 / MinIO
# --------------------------------------------------------------------------
def load_minio_env(mc_config: Path) -> Tuple[Dict[str, str], str]:
    cfg = json.loads(mc_config.read_text())
    alias = cfg.get("aliases", {}).get("local")
    if not alias:
        raise SystemExit(f"no 'local' alias in {mc_config}")
    env = {
        "AWS_ACCESS_KEY_ID": alias["accessKey"],
        "AWS_SECRET_ACCESS_KEY": alias["secretKey"],
        "AWS_DEFAULT_REGION": alias.get("region") or "us-east-1",
    }
    return env, alias.get("url", "http://127.0.0.1:9000")


def mc_du(mc: str, bucket: str) -> Dict[str, Any]:
    res = sh([mc, "du", "--json", f"local/{bucket}"])
    out: Dict[str, Any] = {"raw_returncode": res.returncode}
    if res.returncode != 0:
        out["error"] = res.stderr.strip()[:500]
        return out
    best: Optional[Dict[str, Any]] = None
    for line in res.stdout.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if "size" in obj:
            best = obj
    if best:
        out.update(
            {
                "bytes": int(best.get("size", 0)),
                "objects": int(best.get("objects", 0)),
            }
        )
    return out


# --------------------------------------------------------------------------
# Turbofish server process
# --------------------------------------------------------------------------
@dataclass
class ServeProc:
    name: str
    port: int
    bucket: str
    s3_endpoint: str
    serve_bin: Path
    base_env: Dict[str, str]
    log_dir: Path
    proc: Optional[subprocess.Popen] = None
    log_file: Optional[Any] = None

    def _env(self) -> Dict[str, str]:
        env = dict(os.environ)
        env.update(self.base_env)
        env.update(
            {
                "SPND_STORE": "s3",
                "S3_ENDPOINT": self.s3_endpoint,
                "AWS_ENDPOINT_URL": self.s3_endpoint,
                "AWS_S3_BUCKET": self.bucket,
                "SPND_PORT": str(self.port),
                "SPND_WORKERS": "4",
                "SPND_WORKER_CACHE_MB": "64",
                "SPND_WORKER_CACHE_TTL_SEC": "300",
            }
        )
        return env

    def start(self) -> float:
        t0 = time.perf_counter()
        self.log_file = open(self.log_dir / f"serve-{self.name}.log", "ab")
        self.proc = subprocess.Popen(
            [str(self.serve_bin)],
            env=self._env(),
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        wait_port("127.0.0.1", self.port, timeout=60)
        return time.perf_counter() - t0

    def stop(self) -> None:
        if self.proc is None:
            return
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except OSError:
            pass
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except OSError:
                pass
            self.proc.wait(timeout=10)
        self.proc = None
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None

    def restart(self) -> float:
        self.stop()
        return self.start()

    def rss(self) -> Dict[str, Any]:
        if self.proc is None:
            return {}
        return read_proc_status(self.proc.pid)

    def wait_docs(self, client: TurbofishHTTP, ns: str, expected: int, timeout: float = 1800.0) -> float:
        t0 = time.perf_counter()
        deadline = t0 + timeout
        while time.perf_counter() < deadline:
            try:
                h = client.health(ns)
            except Exception:
                h = {}
            if int(h.get("num_docs", -1)) >= expected:
                return time.perf_counter() - t0
            time.sleep(0.25)
        raise TimeoutError(f"{self.name}: num_docs never reached {expected}")


# --------------------------------------------------------------------------
# Qdrant process control (for the honest "cold process" window only)
# --------------------------------------------------------------------------
@dataclass
class QdrantProc:
    pid: Optional[int] = None
    binary: str = DEFAULT_QDRANT_BIN
    cwd: str = "/workspace"
    log_path: Path = Path("/tmp/qdrant-perf.log")
    proc: Optional[subprocess.Popen] = None

    def discover(self) -> bool:
        pid = pid_by_cmdline("qdrant")
        if pid is None:
            return False
        self.pid = pid
        try:
            self.binary = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[0].decode()
        except OSError:
            self.binary = DEFAULT_QDRANT_BIN
        try:
            self.cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            pass
        return True

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        """False for missing or zombie processes (a zombie has released its locks)."""
        try:
            state = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0]
        except (OSError, IndexError):
            return False
        return state != "Z"

    def stop(self, timeout: float = 120.0) -> None:
        if self.pid is None:
            return
        try:
            os.kill(self.pid, signal.SIGTERM)
        except OSError:
            self.pid = None
            self.proc = None
            return
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc is not None:
                try:
                    self.proc.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    continue
            if not self._pid_alive(self.pid) and http_status("http://127.0.0.1:6333/readyz", timeout=1.0) != 200:
                # Give the kernel a moment to release WAL file locks before restarting.
                time.sleep(1.5)
                self.pid = None
                self.proc = None
                return
            time.sleep(0.25)
        raise TimeoutError("qdrant did not stop within timeout")

    def _reap(self) -> None:
        if self.proc is not None:
            try:
                self.proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                pass
            self.proc = None

    def start(self, timeout: float = 180.0, attempts: int = 3) -> float:
        t0 = time.perf_counter()
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        last_tail = ""
        for attempt in range(1, attempts + 1):
            log = open(self.log_path, "ab")
            proc = subprocess.Popen(
                [self.binary],
                cwd=self.cwd,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            deadline = time.perf_counter() + timeout
            while time.perf_counter() < deadline:
                if proc.poll() is not None:
                    last_tail = _tail(self.log_path, 20)
                    break
                if http_status("http://127.0.0.1:6333/readyz", timeout=1.0) == 200:
                    self.pid = proc.pid
                    self.proc = proc
                    return time.perf_counter() - t0
                time.sleep(0.2)
            if proc.poll() is None:
                raise TimeoutError("qdrant did not become ready after restart")
            self._reap()
            # A stale WAL lock can make the first restart attempt panic; retry.
            time.sleep(2.0)
        raise TimeoutError(f"qdrant restart failed after {attempts} attempts: {last_tail}")

    def rss(self) -> Dict[str, Any]:
        pid = self.pid or pid_by_cmdline(self.binary)
        return read_proc_status(pid) if pid else {}


# --------------------------------------------------------------------------
# ingestion
# --------------------------------------------------------------------------
def tf_rows(ds: Dict[str, Any], start: int, end: int) -> List[Dict[str, Any]]:
    docs, ids = ds["docs"], ds["ids"]
    rows: List[Dict[str, Any]] = []
    for i in range(start, end):
        rows.append(
            {
                "id": int(ids[i]),
                "text": ds["texts"][i],
                "vector": docs[i].tolist(),
                "category": ds["categories"][i],
                "ts": 1700000000 + i,
                "public": bool(i % 3 != 0),
            }
        )
    return rows


def qdrant_payloads(ds: Dict[str, Any], start: int, end: int) -> List[Dict[str, Any]]:
    # Same attributes as Turbofish stores, so storage bytes are comparable.
    return [
        {
            "text": ds["texts"][i],
            "category": ds["categories"][i],
            "ts": 1700000000 + i,
            "public": bool(i % 3 != 0),
        }
        for i in range(start, end)
    ]


def ingest_turbofish(
    srv: ServeProc,
    ns: str,
    ds: Dict[str, Any],
    batch_size: int,
    progress: Callable[[str], None],
) -> Dict[str, Any]:
    client = TurbofishHTTP(port=srv.port)
    try:
        client.create(ns, distance_metric="cosine")
        n = int(ds["ids"].shape[0])
        latencies: List[float] = []
        t0 = time.perf_counter()
        for start in range(0, n, batch_size):
            end = min(start + batch_size, n)
            _res, dt = client.write(ns, tf_rows(ds, start, end))
            latencies.append(dt)
            if (start // batch_size) % 10 == 0:
                progress(f"  {srv.name}: wrote {end}/{n} docs")
        write_seconds = time.perf_counter() - t0
        health_seconds = srv.wait_docs(client, ns, n)
        stats = summarize(latencies)
        # Fold the per-segment deltas into one global IVF base (as bench1m does).
        t_c = time.perf_counter()
        client.compact(ns)
        compact_seconds = time.perf_counter() - t_c
        health2 = srv.wait_docs(client, ns, n)
        h = client.health(ns)
        return {
            "engine": "turbofish",
            "endpoint": srv.s3_endpoint,
            "namespace": ns,
            "docs": n,
            "batch_size": batch_size,
            "write_seconds": write_seconds,
            "docs_per_sec": n / write_seconds if write_seconds > 0 else None,
            "batch_latency": stats,
            "health_wait_seconds": health_seconds,
            "compact_seconds": compact_seconds,
            "health_wait_after_compact_seconds": health2,
            "num_docs_reported": h.get("num_docs"),
            "head": h.get("head", ""),
        }
    finally:
        client.close()


def ingest_qdrant(
    qd: QdrantHTTP,
    ds: Dict[str, Any],
    batch_size: int,
    progress: Callable[[str], None],
) -> Dict[str, Any]:
    n = int(ds["ids"].shape[0])
    qd.create(dim=int(ds["docs"].shape[1]), on_disk_payload=True)
    latencies: List[float] = []
    t0 = time.perf_counter()
    for start in range(0, n, batch_size):
        end = min(start + batch_size, n)
        dt = qd.upsert(ds["ids"][start:end], ds["docs"][start:end], qdrant_payloads(ds, start, end))
        latencies.append(dt)
        if (start // batch_size) % 10 == 0:
            progress(f"  qdrant: wrote {end}/{n} docs")
    write_seconds = time.perf_counter() - t0
    index_wait = qd.wait_ready(n, timeout=1800)
    return {
        "engine": "qdrant",
        "collection": qd.collection,
        "docs": n,
        "batch_size": batch_size,
        "write_seconds": write_seconds,
        "docs_per_sec": n / write_seconds if write_seconds > 0 else None,
        "batch_latency": summarize(latencies),
        "index_wait_seconds": index_wait,
        "collection_info": qd.info(),
    }


# --------------------------------------------------------------------------
# recall tuning and measurement
# --------------------------------------------------------------------------
def measure(
    fn: Callable[[Sequence[float]], Tuple[List[int], float]],
    queries: np.ndarray,
    gt: np.ndarray,
) -> Dict[str, Any]:
    latencies: List[float] = []
    got: List[List[int]] = []
    wall0 = time.perf_counter()
    for q in queries:
        ids, dt = fn(q)
        latencies.append(dt)
        got.append(ids)
    wall = time.perf_counter() - wall0
    out = summarize(latencies, wall=wall)
    out["first_query_ms"] = latencies[0] * 1e3 if latencies else None
    out["recall_at_10"] = mean_recall(gt, got)
    return out


def tune(
    label: str,
    fn_factory: Callable[[int], Callable[[Sequence[float]], Tuple[List[int], float]]],
    params: Sequence[int],
    queries: np.ndarray,
    gt: np.ndarray,
    target: float,
    progress: Callable[[str], None],
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    points: List[Dict[str, Any]] = []
    for p in params:
        fn = fn_factory(int(p))
        res = measure(fn, queries, gt)
        res["param"] = int(p)
        points.append(res)
        progress(
            f"  tune {label} param={p}: recall@10={res['recall_at_10']:.4f} "
            f"p50={res['p50_ms']:.2f}ms p95={res['p95_ms']:.2f}ms"
        )
    best = min(points, key=lambda r: (abs(r["recall_at_10"] - target), r.get("p50_ms", 0.0)))
    return points, best


# --------------------------------------------------------------------------
# S3 request counting via `mc admin trace`
# --------------------------------------------------------------------------
def count_s3_requests(
    mc: str,
    bucket: str,
    queries: np.ndarray,
    fn: Callable[[Sequence[float]], Tuple[List[int], float]],
    log_dir: Path,
    label: str,
    settle: float = 2.0,
) -> Dict[str, Any]:
    path = log_dir / f"s3trace-{label}.jsonl"
    with open(path, "wb") as out:
        proc = subprocess.Popen(
            [mc, "admin", "trace", "--json", "local"],
            stdout=out,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(settle)  # let the trace stream connect
        t0 = time.perf_counter()
        wall0 = time.perf_counter()
        for q in queries:
            fn(q)
        wall = time.perf_counter() - wall0
        elapsed = time.perf_counter() - t0
        time.sleep(1.0)  # flush trailing events
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    by_api: Dict[str, int] = {}
    bytes_out = 0
    total = 0
    parsed = 0
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            api = str(obj.get("api", ""))
            obj_path = str(obj.get("path", ""))
            # Only count this run's bucket, not other tenants or mc's own calls.
            if not api.startswith("s3."):
                continue
            if f"/{bucket}" not in obj_path:
                continue
            parsed += 1
            total += 1
            by_api[api] = by_api.get(api, 0) + 1
            try:
                stats = obj.get("callStats") or {}
                bytes_out += int(stats.get("tx") or obj.get("size") or 0)
            except (TypeError, ValueError):
                pass
    out = {
        "label": label,
        "bucket": bucket,
        "queries": int(len(queries)),
        "wall_seconds": wall,
        "elapsed_seconds": elapsed,
        "trace_events_parsed": parsed,
        "s3_requests": total,
        "s3_requests_per_query": total / len(queries) if len(queries) else None,
        "response_bytes": bytes_out,
        "response_bytes_per_query": bytes_out / len(queries) if len(queries) else None,
        "by_api": dict(sorted(by_api.items())),
        "trace_file": str(path),
    }
    return out


# --------------------------------------------------------------------------
# environment capture
# --------------------------------------------------------------------------
def collect_env(repo: Path, serve_bin: Path, mc: str, out_dir: Path) -> Dict[str, Any]:
    cpu_model = ""
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    mem_kb = None
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_kb = int(line.split()[1])
                break
    except OSError:
        pass

    py_versions: Dict[str, str] = {}
    try:
        import qdrant_client  # noqa: F401
        import importlib.metadata as md

        py_versions["qdrant_client"] = md.version("qdrant-client")
    except Exception:
        py_versions["qdrant_client"] = "missing"
    py_versions["numpy"] = np.__version__

    qdrant_version = ""
    try:
        with urllib.request.urlopen("http://127.0.0.1:6333/", timeout=3) as resp:
            qdrant_version = json.loads(resp.read().decode()).get("version", "")
    except Exception:
        pass

    toxiproxy: Any = {}
    try:
        with urllib.request.urlopen("http://127.0.0.1:8474/proxies", timeout=3) as resp:
            proxies = json.loads(resp.read().decode())
        for name, p in proxies.items():
            toxiproxy[name] = {
                "listen": p.get("listen"),
                "upstream": p.get("upstream"),
                "enabled": p.get("enabled"),
                "toxics": [
                    {
                        "type": t.get("type"),
                        "stream": t.get("stream"),
                        "attributes": t.get("attributes"),
                    }
                    for t in p.get("toxics", [])
                ],
            }
    except Exception as exc:
        toxiproxy = {"error": str(exc)}

    minio_version = ""
    res = sh([mc, "admin", "info", "local", "--json"], timeout=60)
    if res.returncode == 0:
        for line in res.stdout.splitlines():
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            info = obj.get("info", {})
            servers = info.get("servers") or []
            if servers and servers[0].get("version"):
                minio_version = servers[0]["version"]
                break
            if info.get("version"):
                minio_version = info["version"]
                break

    git_head = sh(["git", "-C", str(repo), "rev-parse", "HEAD"]).stdout.strip()
    moon_version = ""
    for moon_cmd in (["moon", "version"], [str(Path.home() / ".moon/bin/moon"), "version"]):
        try:
            res = sh(moon_cmd, timeout=30)
            if res.returncode == 0 and res.stdout.strip():
                moon_version = res.stdout.strip()
                break
        except Exception:
            continue

    return {
        "captured_at": iso_now(),
        "hostname": socket.gethostname(),
        "kernel": os.uname().release,
        "machine": os.uname().machine,
        "cpu_model": cpu_model,
        "nproc": os.cpu_count(),
        "mem_total_kb": mem_kb,
        "python": sys.version.split()[0],
        "python_packages": py_versions,
        "moon_version": moon_version,
        "turbofish_git_head": git_head,
        "serve_binary": str(serve_bin),
        "serve_binary_sha256": sha256_file(serve_bin),
        "serve_binary_mtime": datetime.fromtimestamp(serve_bin.stat().st_mtime, timezone.utc).isoformat()
        if serve_bin.exists()
        else None,
        "minio_version": minio_version,
        "qdrant_version": qdrant_version,
        "toxiproxy_config": toxiproxy,
        "client_cpu_affinity": sorted(os.sched_getaffinity(0)),
        "out_dir": str(out_dir),
    }


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    repo = here.parent
    p = argparse.ArgumentParser(description="Fair Turbofish vs Qdrant vector benchmark")
    p.add_argument("--docs", type=int, default=50_000)
    p.add_argument("--dim", type=int, default=128)
    p.add_argument("--clusters", type=int, default=32, help="data-generation clusters (not IVF nlist)")
    p.add_argument("--noise", type=float, default=0.20)
    p.add_argument("--qnoise", type=float, default=0.05)
    p.add_argument("--seed", type=int, default=20261115)
    p.add_argument("--queries", type=int, default=400, help="measured queries per repetition")
    p.add_argument("--tuning-queries", type=int, default=100)
    p.add_argument("--cold-queries", type=int, default=20, help="queries per cold restart repetition")
    p.add_argument("--batch-size", type=int, default=1000)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--cold-reps", type=int, default=3)
    p.add_argument("--target-recall", type=float, default=0.95)
    p.add_argument("--burnin", type=int, default=100)
    p.add_argument(
        "--tf-nprobe", type=str, default="1,2,4,8,16,32,64",
        help="comma separated nprobe tuning grid",
    )
    p.add_argument(
        "--qdrant-ef", type=str, default="16,24,32,48,64,80,96,128,160,192,224,256,384",
        help="comma separated hnsw_ef tuning grid",
    )
    p.add_argument("--serve-bin", type=Path,
                   default=repo / "_build/native/release/build/cmd/serve/serve.exe")
    p.add_argument("--repo", type=Path, default=repo)
    p.add_argument("--out-dir", type=Path, default=here / "results")
    p.add_argument("--work-dir", type=Path, default=None)
    p.add_argument("--mc", default=DEFAULT_MC)
    p.add_argument("--mc-config", type=Path, default=Path.home() / ".mc/config.json")
    p.add_argument("--dns", default="127.0.0.1")
    p.add_argument("--tf-port", type=int, default=8081)
    p.add_argument("--tf-toxi-port", type=int, default=8082)
    p.add_argument("--minio-endpoint", default="http://127.0.0.1:9000")
    p.add_argument("--toxi-endpoint", default="http://127.0.0.1:19000")
    p.add_argument("--qdrant-storage", type=Path, default=Path("/workspace/storage"))
    p.add_argument("--namespace", default="perf")
    p.add_argument("--trace-ingest-docs", type=int, default=1000,
                   help="if >0, trace S3 requests for a throwaway ingest of this many docs")
    p.add_argument("--no-cold", action="store_true")
    p.add_argument("--no-qdrant-restart", action="store_true",
                   help="skip the Qdrant service restart (cold window becomes unavailable)")
    p.add_argument("--no-pin", action="store_true", help="do not pin the client to one CPU")
    p.add_argument("--keep-data", action="store_true", help="keep bucket/collection after the run")
    p.add_argument("--smoke", action="store_true",
                   help="small functional run (numbers not meaningful, Qdrant below HNSW threshold)")
    p.add_argument("--resume", action="store_true", help="reuse existing dataset.npz in --work-dir")
    return p.parse_args(argv)


def pin_client(args: argparse.Namespace) -> None:
    if args.no_pin or os.environ.get("PERF_PINNED") == "1":
        return
    if os.cpu_count() < 3:
        return
    taskset = shutil.which("taskset")
    if not taskset:
        return
    cpu = 3 if os.cpu_count() >= 4 else os.cpu_count() - 1
    env = dict(os.environ)
    env["PERF_PINNED"] = "1"
    os.execve(
        taskset,
        [taskset, "-c", str(cpu), sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]],
        env,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    pin_client(args)

    if args.smoke:
        args.docs = min(args.docs, 3_000)
        args.queries = min(args.queries, 40)
        args.tuning_queries = min(args.tuning_queries, 20)
        args.cold_queries = min(args.cold_queries, 5)
        args.cold_reps = min(args.cold_reps, 1)
        args.burnin = min(args.burnin, 10)
        args.tf_nprobe = "1,4,16"
        args.qdrant_ef = "16,64"
        args.trace_ingest_docs = min(args.trace_ingest_docs, 500)

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = f"{run_id}-{os.getpid()}"
    work = Path(args.work_dir or f"/tmp/turbofish-perf-{suffix}")
    work.mkdir(parents=True, exist_ok=True)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out_dir / f"compare-{suffix}.json"
    tf_ns = args.namespace
    bucket_direct = f"perf-w2-direct-{suffix.lower()}"
    bucket_toxi = f"perf-w2-toxi-{suffix.lower()}"
    qd_collection = f"perf_w2_{run_id.lower()}_{os.getpid()}"
    result: Dict[str, Any] = {
        "schema": 2,
        "run_id": run_id,
        "started_at": iso_now(),
        "smoke": bool(args.smoke),
        "config": {
            "docs": args.docs,
            "dim": args.dim,
            "clusters": args.clusters,
            "noise": args.noise,
            "qnoise": args.qnoise,
            "seed": args.seed,
            "queries": args.queries,
            "tuning_queries": args.tuning_queries,
            "cold_queries": args.cold_queries,
            "batch_size": args.batch_size,
            "reps": args.reps,
            "cold_reps": args.cold_reps,
            "target_recall": args.target_recall,
            "burnin": args.burnin,
            "concurrency": 1,
            "top_k": TOP_K,
            "tf_nprobe_grid": [int(x) for x in args.tf_nprobe.split(",") if x],
            "qdrant_ef_grid": [int(x) for x in args.qdrant_ef.split(",") if x],
            "client_cpu_pinned": not args.no_pin,
            "direct_endpoint": args.minio_endpoint,
            "toxiproxy_endpoint": args.toxi_endpoint,
            "qdrant_storage": str(args.qdrant_storage),
        },
        "buckets": {"direct": bucket_direct, "toxiproxy": bucket_toxi},
        "qdrant_collection": qd_collection,
        "work_dir": str(work),
        "warm_definition": (
            f"{args.burnin} burn-in queries per engine, then measured queries; "
            "service kept running, worker/metadata caches and OS caches warm"
        ),
        "cold_definition": (
            "service process restarted (Turbofish server / Qdrant), no burn-in, "
            "first 20 queries measured. OS page cache and MinIO are NOT dropped; "
            "Qdrant serves from local disk/mmap, Turbofish must fetch objects from MinIO"
        ),
        "errors": [],
    }

    def progress(msg: str) -> None:
        print(msg, flush=True)

    def record_error(stage: str, exc: BaseException) -> None:
        import traceback

        result["errors"].append(
            {"stage": stage, "error": f"{type(exc).__name__}: {exc}", "traceback": traceback.format_exc()}
        )
        progress(f"ERROR in {stage}: {type(exc).__name__}: {exc}")

    # -- preflight -----------------------------------------------------
    serve_bin = args.serve_bin.resolve()
    if not serve_bin.exists():
        raise SystemExit(
            f"missing serve binary {serve_bin}; run perf/box_bootstrap.sh inside the VM first"
        )
    for url in (
        "http://127.0.0.1:9000/minio/health/live",
        "http://127.0.0.1:6333/readyz",
        "http://127.0.0.1:8474/proxies",
    ):
        if http_status(url) != 200:
            raise SystemExit(f"required service not healthy: {url}")
    if not Path(args.mc).exists():
        raise SystemExit(f"mc not found at {args.mc}")

    progress(f"== run {run_id} (smoke={args.smoke}) work={work}")
    progress("== collecting environment")
    minio_env, _minio_url = load_minio_env(args.mc_config)
    result["environment"] = collect_env(args.repo, serve_bin, args.mc, args.out_dir)

    # -- dataset -------------------------------------------------------
    npz = work / "dataset.npz"
    if args.resume and npz.exists():
        progress("== loading existing dataset")
        z = np.load(npz)
        ds = {
            "docs": z["docs"], "ids": z["ids"], "queries": z["queries"], "gt": z["gt"],
            "texts": list(z["texts"]), "categories": list(z["categories"]),
            "query_docs": z["query_docs"],
        }
        ds["sha256"] = result["environment"].get("dataset_sha256", "")
    else:
        progress(f"== generating dataset: docs={args.docs} dim={args.dim} clusters={args.clusters}")
        t0 = time.perf_counter()
        ds = build_dataset(args)
        progress(
            f"   dataset sha256={ds['sha256'][:16]}… exact GT computed in {time.perf_counter()-t0:.1f}s"
        )
        np.savez(
            npz,
            docs=ds["docs"], ids=ds["ids"], queries=ds["queries"], gt=ds["gt"],
            texts=np.asarray(ds["texts"]), categories=np.asarray(ds["categories"]),
            query_docs=ds["query_docs"],
        )
    result["environment"]["dataset_sha256"] = ds["sha256"]
    result["dataset"] = {
        "docs": int(ds["ids"].shape[0]),
        "dim": int(ds["docs"].shape[1]),
        "queries_total": int(ds["queries"].shape[0]),
        "queries_measured_per_rep": args.queries,
        "tuning_queries": args.tuning_queries,
        "cold_queries_per_rep": args.cold_queries,
        "dtype": "float32, L2-normalised (cosine)",
        "ground_truth": "exact brute-force cosine top-10 over all docs (numpy, no index involved)",
        "query_slice_measured": [0, args.queries],
        "query_slice_tuning": [args.queries, args.queries + args.tuning_queries],
        "query_slice_cold": [
            args.queries + args.tuning_queries,
            args.queries + args.tuning_queries + args.cold_queries * args.cold_reps,
        ],
        "file": str(npz),
    }

    q_measured = ds["queries"][: args.queries]
    gt_measured = ds["gt"][: args.queries]
    q_tuning = ds["queries"][args.queries: args.queries + args.tuning_queries]
    gt_tuning = ds["gt"][args.queries: args.queries + args.tuning_queries]
    cold_start = args.queries + args.tuning_queries
    q_cold = ds["queries"][cold_start: cold_start + args.cold_queries * args.cold_reps]
    gt_cold = ds["gt"][cold_start: cold_start + args.cold_queries * args.cold_reps]

    # -- buckets -------------------------------------------------------
    progress("== preparing MinIO buckets")
    for bucket in (bucket_direct, bucket_toxi):
        res = sh([args.mc, "mb", "--ignore-existing", f"local/{bucket}"])
        if res.returncode != 0:
            record_error("mc mb", RuntimeError(res.stderr.strip()[:300]))

    base_env = dict(minio_env)
    # Credentials come from ~/.mc/config.json and are never printed.
    srv_direct = ServeProc(
        name="direct", port=args.tf_port, bucket=bucket_direct,
        s3_endpoint=args.minio_endpoint, serve_bin=serve_bin,
        base_env=base_env, log_dir=work,
    )
    srv_toxi = ServeProc(
        name="toxi", port=args.tf_toxi_port, bucket=bucket_toxi,
        s3_endpoint=args.toxi_endpoint, serve_bin=serve_bin,
        base_env=base_env, log_dir=work,
    )
    qd = QdrantHTTP(port=6333, collection=qd_collection)
    qproc = QdrantProc()
    tf_clients: Dict[str, TurbofishHTTP] = {}

    try:
        # -- qdrant ingest (no Turbofish load) -------------------------
        progress("== ingesting into Qdrant (batch=%d)" % args.batch_size)
        result["ingest"] = {}
        try:
            result["ingest"]["qdrant"] = ingest_qdrant(qd, ds, args.batch_size, progress)
            progress(
                "   qdrant wrote %.1fs (%.0f docs/s), index wait %.1fs"
                % (
                    result["ingest"]["qdrant"]["write_seconds"],
                    result["ingest"]["qdrant"]["docs_per_sec"] or 0,
                    result["ingest"]["qdrant"]["index_wait_seconds"],
                )
            )
        except Exception as exc:
            record_error("ingest:qdrant", exc)

        # -- turbofish ingest: direct MinIO ---------------------------
        for srv, key in ((srv_direct, "turbofish_direct"), (srv_toxi, "turbofish_toxiproxy")):
            progress(f"== ingesting into Turbofish via {srv.s3_endpoint} (bucket={srv.bucket})")
            srv.start()
            try:
                result["ingest"][key] = ingest_turbofish(srv, tf_ns, ds, args.batch_size, progress)
                ing = result["ingest"][key]
                progress(
                    "   %s wrote %.1fs (%.0f docs/s), compact %.1fs, head=%s"
                    % (key, ing["write_seconds"], ing["docs_per_sec"] or 0,
                       ing["compact_seconds"], str(ing["head"])[:24])
                )
            except Exception as exc:
                record_error(f"ingest:{key}", exc)
            finally:
                srv.stop()

        # -- start both TF servers for querying -----------------------
        progress("== starting Turbofish servers for query phase")
        srv_direct.start()
        srv_toxi.start()
        SanityClient = TurbofishHTTP(port=srv_direct.port)
        SanityClient.health(tf_ns)
        SanityClient.close()
        SanityClient = TurbofishHTTP(port=srv_toxi.port)
        SanityClient.health(tf_ns)
        SanityClient.close()

        # -- warm-up + tuning -----------------------------------------
        tf_clients.update(
            {
                "tf_direct": TurbofishHTTP(port=srv_direct.port),
                "tf_toxi": TurbofishHTTP(port=srv_toxi.port),
            }
        )
        progress(f"== burn-in: {args.burnin} queries per engine")
        for name, client in tf_clients.items():
            for q in q_tuning[: args.burnin]:
                client.query(tf_ns, q, TOP_K, 8)
        for q in q_tuning[: args.burnin]:
            qd.query(q, TOP_K, 64)

        result["recall_tuning"] = {}
        chosen: Dict[str, Dict[str, Any]] = {}
        for name, client in tf_clients.items():
            progress(f"== tuning {name} nprobe (target recall {args.target_recall})")
            points, best = tune(
                name,
                lambda p, c=client: (lambda q: c.query(tf_ns, q, TOP_K, p)),
                [int(x) for x in args.tf_nprobe.split(",") if x],
                q_tuning, gt_tuning, args.target_recall, progress,
            )
            result["recall_tuning"][name] = {"grid": points, "chosen": best}
            chosen[name] = best

        progress("== tuning qdrant hnsw_ef")
        points, best = tune(
            "qdrant",
            lambda p: (lambda q: qd.query(q, TOP_K, p)),
            [int(x) for x in args.qdrant_ef.split(",") if x],
            q_tuning, gt_tuning, args.target_recall, progress,
        )
        result["recall_tuning"]["qdrant"] = {"grid": points, "chosen": best}
        chosen["qdrant"] = best

        engine_fns: Dict[str, Callable[[Sequence[float]], Tuple[List[int], float]]] = {
            "tf_direct": (lambda q: tf_clients["tf_direct"].query(tf_ns, q, TOP_K, chosen["tf_direct"]["param"])),
            "tf_toxi": (lambda q: tf_clients["tf_toxi"].query(tf_ns, q, TOP_K, chosen["tf_toxi"]["param"])),
            "qdrant": (lambda q: qd.query(q, TOP_K, chosen["qdrant"]["param"])),
        }
        result["chosen_params"] = {
            name: {
                "param": chosen[name]["param"],
                "tuning_recall_at_10": chosen[name]["recall_at_10"],
                "tuning_p50_ms": chosen[name]["p50_ms"],
                "tf_nprobe": chosen[name]["param"] if name.startswith("tf_") else None,
                "qdrant_hnsw_ef": chosen[name]["param"] if name == "qdrant" else None,
            }
            for name in chosen
        }

        # -- warm, interleaved repetitions ----------------------------
        progress(f"== warm measurement: {args.reps} reps x {args.queries} queries, engines interleaved")
        engine_names = ["tf_direct", "tf_toxi", "qdrant"]
        warm: Dict[str, List[Dict[str, Any]]] = {name: [] for name in engine_names}
        orders = [
            ["tf_direct", "tf_toxi", "qdrant"],
            ["qdrant", "tf_direct", "tf_toxi"],
            ["tf_toxi", "qdrant", "tf_direct"],
        ]
        for rep in range(args.reps):
            order = orders[rep % len(orders)]
            progress(f"  rep {rep + 1}/{args.reps}: order={order}")
            for name in order:
                res = measure(engine_fns[name], q_measured, gt_measured)
                res["rep"] = rep + 1
                warm[name].append(res)
                progress(
                    "    %-9s recall=%.4f p50=%.2fms p95=%.2fms p99=%.2fms qps=%.1f"
                    % (name, res["recall_at_10"], res["p50_ms"], res["p95_ms"], res["p99_ms"], res["qps"])
                )
            result["warm"] = warm
            result["warm_pooled"] = {
                name: _pool_reps(warm[name]) for name in engine_names
            }

        # -- RSS + storage (after warm, before restarts) --------------
        progress("== capturing RSS and storage size")
        result["rss"] = {
            "tf_direct": srv_direct.rss(),
            "tf_toxi": srv_toxi.rss(),
            "qdrant": qproc.rss(),
            "minio": read_proc_status(pid_by_pgrep("minio server")) if pid_by_pgrep("minio server") else {},
        }
        result["storage"] = {
            "minio_direct": mc_du(args.mc, bucket_direct),
            "minio_toxiproxy": mc_du(args.mc, bucket_toxi),
            "qdrant_collection": {
                "path": str(args.qdrant_storage / "collections" / qd_collection),
                "bytes": _du_bytes(args.qdrant_storage / "collections" / qd_collection),
                "apparent_bytes": _du_apparent_bytes(args.qdrant_storage / "collections" / qd_collection),
                "sum_of_file_sizes": dir_size_bytes(args.qdrant_storage / "collections" / qd_collection),
                "info": qd.info(),
            },
        }
        for key in ("minio_direct", "minio_toxiproxy"):
            du = result["storage"][key]
            if "bytes" in du:
                du["bytes_per_doc"] = du["bytes"] / args.docs
        qst = result["storage"]["qdrant_collection"]
        if qst.get("bytes"):
            qst["bytes_per_doc"] = qst["bytes"] / args.docs

        # -- real S3 request counts (trace, separate from latency) ----
        progress("== counting S3 requests with `mc admin trace` (separate window)")
        result["s3_requests"] = {}
        count_queries = q_measured[: min(100, len(q_measured))]
        for name in ("tf_direct", "tf_toxi"):
            try:
                result["s3_requests"][name] = count_s3_requests(
                    args.mc, result["buckets"]["direct" if name == "tf_direct" else "toxiproxy"],
                    count_queries, engine_fns[name], work, name,
                )
                sr = result["s3_requests"][name]
                progress(
                    "   %s: %.2f S3 requests/query (%s)"
                    % (name, sr["s3_requests_per_query"] or 0, sr["by_api"])
                )
            except Exception as exc:
                record_error(f"trace:{name}", exc)

        # Cold request counts: restart, then trace the first queries. Kept out of
        # the latency window because tracing adds overhead.
        progress("== counting S3 requests for post-restart (cold) queries")
        for name, srv in (("tf_direct", srv_direct), ("tf_toxi", srv_toxi)):
            if args.no_cold:
                break
            try:
                srv.restart()
                client = tf_clients[name]
                client.reconnect()
                result["s3_requests"][name + "_cold"] = count_s3_requests(
                    args.mc, srv.bucket, q_cold[: args.cold_queries], engine_fns[name], work, name + "-cold",
                )
                sr = result["s3_requests"][name + "_cold"]
                progress(
                    "   %s cold: %.2f S3 requests/query (%s)"
                    % (name, sr["s3_requests_per_query"] or 0, sr["by_api"])
                )
            except Exception as exc:
                record_error(f"trace-cold:{name}", exc)

        if args.trace_ingest_docs > 0:
            result["s3_requests"]["ingest"] = {}
            probe_ns = f"{tf_ns}-ingestprobe-{os.getpid()}"
            for name, srv in (("tf_direct", srv_direct), ("tf_toxi", srv_toxi)):
                client = tf_clients[name]
                try:
                    client.create(probe_ns)
                    fn = lambda q, c=client: c.write(probe_ns, tf_rows(ds, 0, args.trace_ingest_docs))
                    result["s3_requests"]["ingest"][name] = _trace_call(
                        args.mc, srv.bucket, fn, work, f"{name}-ingest"
                    )
                except Exception as exc:
                    record_error(f"trace-ingest:{name}", exc)
        # -- cold ------------------------------------------------------
        if not args.no_cold:
            progress("== cold window: restart each service, measure first queries without burn-in")
            result["cold"] = {}
            for idx, name in enumerate(("tf_direct", "tf_toxi")):
                srv = srv_direct if name == "tf_direct" else srv_toxi
                reps: List[Dict[str, Any]] = []
                for rep in range(args.cold_reps):
                    start = rep * args.cold_queries
                    qs = q_cold[start:start + args.cold_queries]
                    gts = gt_cold[start:start + args.cold_queries]
                    restart_s = srv.restart()
                    client = tf_clients[name]
                    client.reconnect()
                    res = measure(engine_fns[name], qs, gts)
                    res["restart_seconds"] = restart_s
                    res["rep"] = rep + 1
                    reps.append(res)
                    progress(
                        "   %-9s cold rep %d: first=%.1fms p50=%.1fms recall=%.4f"
                        % (name, rep + 1, res["first_query_ms"], res["p50_ms"], res["recall_at_10"])
                    )
                result["cold"][name] = reps
                result["cold"][name + "_summary"] = _pool_reps(reps)

            if not args.no_qdrant_restart:
                try:
                    qproc.discover()
                    before = _qdrant_collections()
                    reps = []
                    for rep in range(args.cold_reps):
                        start = rep * args.cold_queries
                        qs = q_cold[start:start + args.cold_queries]
                        gts = gt_cold[start:start + args.cold_queries]
                        qproc.stop()
                        restart_s = qproc.start()
                        after = _qdrant_collections()
                        if qd_collection not in after:
                            raise RuntimeError(
                                f"qdrant collection {qd_collection} missing after restart "
                                f"(before={before}, after={after})"
                            )
                        qd.reconnect()
                        res = measure(engine_fns["qdrant"], qs, gts)
                        res["restart_seconds"] = restart_s
                        res["rep"] = rep + 1
                        reps.append(res)
                        progress(
                            "   qdrant    cold rep %d: first=%.1fms p50=%.1fms recall=%.4f"
                            % (rep + 1, res["first_query_ms"], res["p50_ms"], res["recall_at_10"])
                        )
                    result["cold"]["qdrant"] = reps
                    result["cold"]["qdrant_summary"] = _pool_reps(reps)
                except Exception as exc:
                    record_error("cold:qdrant-restart", exc)

        # -- post-run storage snapshot (background compaction keeps writing)
        progress("== post-run storage snapshot")
        result["storage_post_run"] = {
            "minio_direct": mc_du(args.mc, bucket_direct),
            "minio_toxiproxy": mc_du(args.mc, bucket_toxi),
            "qdrant_collection": {
                "bytes": _du_bytes(args.qdrant_storage / "collections" / qd_collection),
                "apparent_bytes": _du_apparent_bytes(args.qdrant_storage / "collections" / qd_collection),
            },
        }

        # -- summary table --------------------------------------------
        result["summary"] = summarize_result(result)
        result["finished_at"] = iso_now()
        _write_json(out_path, result)
        progress(f"== wrote {out_path}")
        _print_summary(result)

    except Exception as exc:  # record, then re-raise after cleanup
        record_error("fatal", exc)
        raise

    finally:
        for srv in (srv_direct, srv_toxi):
            try:
                srv.stop()
            except Exception:
                pass
        for client in tf_clients.values():
            try:
                client.close()
            except Exception:
                pass
        if not args.keep_data:
            progress("== cleaning up our bucket/collection (use --keep-data to keep)")
            for bucket in (bucket_direct, bucket_toxi):
                if bucket.startswith("perf-w2-"):
                    sh([args.mc, "rb", "--force", f"local/{bucket}"])
            if qd_collection.startswith("perf_w2_"):
                try:
                    qd.delete()
                except Exception:
                    pass
        if not result.get("finished_at"):
            result["finished_at"] = iso_now()
            result["summary"] = summarize_result(result)
            _write_json(out_path, result)
    return 0


def _du_bytes(path: Path) -> Optional[int]:
    """Allocated disk bytes (sparse mmap files are not counted as fully used)."""
    if not path.exists():
        return None
    res = sh(["du", "-s", "-B1", str(path)])
    if res.returncode != 0:
        return None
    return int(res.stdout.split()[0])


def _du_apparent_bytes(path: Path) -> Optional[int]:
    if not path.exists():
        return None
    res = sh(["du", "-sb", str(path)])
    if res.returncode != 0:
        return None
    return int(res.stdout.split()[0])


def _tail(path: Path, lines: int = 20) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return ""


def _qdrant_collections() -> List[str]:
    try:
        with urllib.request.urlopen("http://127.0.0.1:6333/collections", timeout=10) as resp:
            data = json.loads(resp.read().decode())
        return [c["name"] for c in data.get("result", {}).get("collections", [])]
    except Exception:
        return []


def _trace_call(
    mc: str, bucket: str, fn: Callable[[Any], Any], log_dir: Path, label: str
) -> Dict[str, Any]:
    path = log_dir / f"s3trace-{label}.jsonl"
    with open(path, "wb") as out:
        proc = subprocess.Popen(
            [mc, "admin", "trace", "--json", "local"],
            stdout=out, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        time.sleep(2.0)
        t0 = time.perf_counter()
        fn(None)
        elapsed = time.perf_counter() - t0
        time.sleep(1.0)
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    by_api: Dict[str, int] = {}
    total = 0
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            api = str(obj.get("api", ""))
            if not api.startswith("s3.") or f"/{bucket}" not in str(obj.get("path", "")):
                continue
            total += 1
            by_api[api] = by_api.get(api, 0) + 1
    return {"elapsed_seconds": elapsed, "s3_requests": total, "by_api": by_api, "trace_file": str(path)}


def _pool_reps(reps: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    """Aggregate per-repetition statistics without pretending they are raw samples."""
    out: Dict[str, Any] = {"reps": len(reps)}
    for key in ("p50_ms", "p95_ms", "p99_ms", "mean_ms", "qps", "recall_at_10", "restart_seconds", "first_query_ms"):
        vals = [r[key] for r in reps if r.get(key) is not None]
        if vals:
            out[key] = {
                "mean": float(np.mean(vals)),
                "min": float(np.min(vals)),
                "max": float(np.max(vals)),
                "values": [float(v) for v in vals],
            }
    return out


def summarize_result(result: Dict[str, Any]) -> Dict[str, Any]:
    summary: Dict[str, Any] = {
        "ingest": {},
        "warm": {},
        "cold": {},
        "storage": {},
    }
    ing = result.get("ingest", {})
    for name in ("qdrant", "turbofish_direct", "turbofish_toxiproxy"):
        if name in ing:
            row = {
                "write_seconds": ing[name].get("write_seconds"),
                "docs_per_sec": ing[name].get("docs_per_sec"),
            }
            if name == "qdrant":
                row["index_wait_seconds"] = ing[name].get("index_wait_seconds")
            else:
                row["compact_seconds"] = ing[name].get("compact_seconds")
            summary["ingest"][name] = row
    for name, reps in result.get("warm", {}).items():
        pool = result.get("warm_pooled", {}).get(name, {})
        summary["warm"][name] = {
            "recall_at_10": [r.get("recall_at_10") for r in reps],
            "p50_ms": [r.get("p50_ms") for r in reps],
            "p95_ms": [r.get("p95_ms") for r in reps],
            "p99_ms": [r.get("p99_ms") for r in reps],
            "qps": [r.get("qps") for r in reps],
            "pooled": pool,
        }
    for name in ("tf_direct", "tf_toxi", "qdrant"):
        summary["cold"][name] = result.get("cold", {}).get(name + "_summary")
    for key in ("minio_direct", "minio_toxiproxy"):
        du = result.get("storage", {}).get(key, {})
        if "bytes" in du:
            summary["storage"][key] = du
    qst = result.get("storage", {}).get("qdrant_collection", {})
    if qst.get("bytes"):
        summary["storage"]["qdrant_collection"] = {
            "bytes": qst["bytes"], "bytes_per_doc": qst.get("bytes_per_doc"),
        }
    return summary


def _write_json(path: Path, obj: Dict[str, Any]) -> None:
    tmp = path.with_suffix(".json.tmp")
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2, default=str)
    os.replace(tmp, path)


def _print_summary(result: Dict[str, Any]) -> None:
    print("\n== summary ==")
    for name, row in result.get("summary", {}).get("warm", {}).items():
        print(
            "%-9s recall=%s p50=%s p95=%s p99=%s qps=%s"
            % (
                name,
                ", ".join(f"{x:.4f}" for x in row["recall_at_10"]),
                ", ".join(f"{x:.2f}" for x in row["p50_ms"]),
                ", ".join(f"{x:.2f}" for x in row["p95_ms"]),
                ", ".join(f"{x:.2f}" for x in row["p99_ms"]),
                ", ".join(f"{x:.1f}" for x in row["qps"]),
            )
        )
    for name, row in result.get("summary", {}).get("ingest", {}).items():
        print(f"ingest {name}: {row}")
    for name, row in result.get("summary", {}).get("storage", {}).items():
        print(f"storage {name}: {row.get('bytes')} bytes ({row.get('bytes_per_doc')} B/doc)")
    if result.get("errors"):
        print(f"errors: {len(result['errors'])} (see JSON)")


if __name__ == "__main__":
    sys.exit(main())
