# Turbofish Deployment & Operations Guide

Turbofish is an **S3-Native Hybrid Search Engine** (BM25 full-text + IVF vector search + metadata filtering). Compute nodes are **100% stateless** and treat Object Storage (AWS S3, Cloudflare R2, MinIO, GCP Storage) as the single source of truth.

---

## 1. Build Performance & Footprint

- **Native Compile Time**: **~2.3 seconds** cold, **< 0.1 seconds** incremental (`moon build --target native --release cmd/serve`).
- **Binary Footprint**: **1.5MB** single standalone native binary (linked only against `libc` and `libcurl`).
- **Cold Boot Latency**: **< 5ms** from process start to serving HTTP requests.
- **Docker Image**: **< 25MB** multi-stage Alpine runtime.

---

## 2. 30-Second Local Quickstart

### Option A: Direct Native Binary
```bash
# 1. Build the release binary
moon build --target native --release cmd/serve

# 2. Run with local filesystem storage (zero dependencies)
SPND_STORE=fs:/tmp/turbofish-data \
SPND_PORT=8080 \
./_build/native/release/build/cmd/serve/serve.exe
```

### Option B: Docker Compose (Turbofish + MinIO S3)
```bash
docker compose up -d
# Turbofish is live at http://localhost:8080
# MinIO S3 Console at http://localhost:9001 (minioadmin / minioadmin)
```

---

## 3. Storage Provider Configurations

Turbofish selects its backing store via `SPND_STORE`:
- `fs:<PATH>`: Local NVMe/SSD directory (ideal for local testing).
- `s3`: Standard S3-compatible object store.
- `sim:<SEED>`: Deterministic multi-cloud latency & failure simulator.

### 3.1 AWS S3 (Production)
```bash
export SPND_STORE=s3
export S3_BUCKET="my-production-turbofish-index"
export AWS_REGION="us-east-1"
# AWS standard credentials automatically detected:
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
./serve.exe
```

### 3.2 Cloudflare R2 (Zero Egress Costs)
Cloudflare R2 provides S3-compatible endpoints with **zero egress bandwidth fees** and standard If-Match CAS support:
```bash
export SPND_STORE=s3
export S3_ENDPOINT="https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
export S3_BUCKET="turbofish-r2"
export S3_REGION="auto"
export AWS_ACCESS_KEY_ID="<R2_ACCESS_KEY_ID>"
export AWS_SECRET_ACCESS_KEY="<R2_SECRET_ACCESS_KEY>"
./serve.exe
```

### 3.3 MinIO / Private Cloud Ceph
```bash
export SPND_STORE=s3
export S3_ENDPOINT="http://10.0.0.100:9000"
export S3_BUCKET="turbofish"
export S3_REGION="us-east-1"
export AWS_ACCESS_KEY_ID="minioadmin"
export AWS_SECRET_ACCESS_KEY="minioadmin"
./serve.exe
```

---

## 4. Enterprise Credential Management & Terraform

In enterprise production, hardcoded API keys are forbidden. Turbofish natively respects the standard cloud ecosystem credential hierarchy.

### 4.1 Environment Variable Precedence Table

| Purpose | Primary (AWS Ecosystem Standard) | Fallback (Turbofish Legacy) | Default |
|---|---|---|---|
| **Access Key** | `AWS_ACCESS_KEY_ID` | `S3_ACCESS_KEY` | `minioadmin` |
| **Secret Key** | `AWS_SECRET_ACCESS_KEY` | `S3_SECRET_KEY` | `minioadmin` |
| **Region** | `AWS_REGION` / `AWS_DEFAULT_REGION` | `S3_REGION` | `us-east-1` |
| **Endpoint** | `AWS_ENDPOINT_URL_S3` / `AWS_ENDPOINT_URL` | `S3_ENDPOINT` | `http://127.0.0.1:9000` |
| **Bucket** | `AWS_S3_BUCKET` | `S3_BUCKET` | `seekpond` |
| **Port** | `SPND_PORT` | `PORT` | `8080` |

### 4.2 Terraform Provisioning (AWS S3 + IAM Policy)

```hcl
# 1. S3 Bucket
resource "aws_s3_bucket" "turbofish" {
  bucket = "turbofish-prod-data"
}

# 2. Least-Privilege IAM Policy for Turbofish Workers
resource "aws_iam_policy" "turbofish_rw" {
  name        = "turbofish-s3-access"
  description = "Allows Turbofish compute nodes to perform CAS, Range GET, PUT, and DELETE"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.turbofish.arn,
          "${aws_s3_bucket.turbofish.arn}/*"
        ]
      }
    ]
  })
}
```

### 4.3 Kubernetes IRSA (EKS IAM Roles for Service Accounts)

Turbofish compute nodes run completely stateless in Kubernetes. Attach the IAM role directly to the Kubernetes `ServiceAccount`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: turbofish-sa
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/turbofish-worker-role
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: turbofish-worker
spec:
  replicas: 3
  selector:
    matchLabels:
      app: turbofish
  template:
    metadata:
      labels:
        app: turbofish
    spec:
      serviceAccountName: turbofish-sa
      containers:
        - name: turbofish
          image: turbofish:latest
          env:
            - name: SPND_STORE
              value: "s3"
            - name: S3_BUCKET
              value: "turbofish-prod-data"
            - name: AWS_REGION
              value: "us-east-1"
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          readinessProbe:
            httpGet:
              path: /v1/namespaces/default/health
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
```

---

## 5. Horizontal Scaling & Scale-to-Zero Architecture

Because all index parts, manifest metadata, and head pointers reside on Object Storage:
1. **Any Worker Serves Any Namespace**: Worker nodes do not hold persistent partitions. If traffic surges on a specific namespace, an arbitrary worker pool can answer queries using cached manifests and Range GETs.
2. **Scale to Zero**: During idle hours (e.g. at night), compute replicas can scale down to `0`. When the first HTTP request arrives, the cold node spins up in **< 5ms**, pulls the compact manifest in a single GET, and serves the query. Storage costs remain strictly based on S3 volume ($0.015/GB/mo on R2 / S3 Standard).
