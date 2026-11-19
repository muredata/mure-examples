# DuckDB 2.0 on Amazon S3 Tables (TPC-DS) — AWS demo

A self-contained demo for a fresh AWS account:

- **TPC-DS at scale factor 10** (about 10 GB raw, 24 tables) generated with DuckDB and stored
  as Apache Iceberg tables in an **Amazon S3 table bucket**.
- **DuckDB 2.0** with the **DuckDB UI** running on **AWS Fargate** (Graviton) in private subnets,
  with the S3 table bucket attached through the S3 Tables Iceberg REST endpoint.
- Access through **Amazon CloudFront** with an **AWS WAF** IP allow list and a **Cognito** sign-in
  enforced by **Lambda@Edge**.
- A ready-made **example notebook** in the UI with metadata queries, TPC-DS queries, a
  `MERGE` into Iceberg and time travel.

Everything is Terraform (`terraform/`), and every step runs through one uv-managed CLI
(`uv run duckdemo ...`).

## Architecture

```
 Browser
   │ HTTPS
   ▼
 Amazon CloudFront ── AWS WAF (IP allow list, rate limit, AWS IP reputation)
   │   └─ Lambda@Edge viewer request: Cognito sign-in (OAuth code flow, CSRF nonce, HttpOnly cookies)
   │ CloudFront VPC origin (no public endpoint)
   ▼
 Internal ALB (private subnets, accepts CloudFront only)
   ▼
 Fargate task (private subnet, no public IP, read-only root FS, non-root, no Linux capabilities)
   ├─ proxy  : HAProxy :8080, checks Origin, strips cookies, rewrites Host/Origin for the UI
   └─ duckdb : DuckDB 2.0 + UI on localhost:4213 (loopback only), 8 vCPU / 32 GiB
          │ SigV4 with the task role
          ├─ S3 Tables interface endpoint ──► Iceberg REST catalog (table bucket)
          ├─ S3 gateway endpoint ───────────► Iceberg data and metadata files
          └─ NAT gateway ───────────────────► ui.duckdb.org only (UI frontend assets)
                                              DNS Firewall blocks every other name
```

| Component | Choice | Why |
|---|---|---|
| Table storage | S3 Tables, SSE-S3, managed maintenance | Compaction, snapshot expiry and unreferenced file removal without a Spark job |
| Catalog access | S3 Tables Iceberg REST endpoint (`ENDPOINT_TYPE s3_tables`) | Native DuckDB support, SigV4 with the task role, no extra services |
| Compute | Fargate ARM64, UI 8 vCPU / 32 GiB / 100 GiB disk; loader 16 vCPU / 64 GiB / 200 GiB | SF10 joins fit in memory; spills go to local disk instead of failing |
| Network | Private subnets, VPC endpoints (S3, S3 Tables, ECR, Logs, STS), 1 NAT | AWS traffic never leaves the AWS network |
| Edge | CloudFront VPC origin → internal ALB | The ALB has no public address at all |
| Auth | Cognito user pool, admin-created users only, optional TOTP MFA | Production-grade sign-in; no shared password |
| Encryption | AWS managed (SSE-S3, CloudWatch Logs, ECR AES-256), TLS to CloudFront | Simple for a demo; see "Going to production" |

### DuckDB settings

Set in `images/duckdb/app/common.py` from task environment variables, then locked
(`lock_configuration = true`) so UI users can't change them:

| Setting | UI task | Loader | Reason |
|---|---|---|---|
| `memory_limit` | 24 GB (of 32 GiB) | 48 GB (of 64 GiB) | Headroom for Python, HTTP buffers, the proxy |
| `threads` | 8 | 16 | One per vCPU |
| `temp_directory` / `max_temp_directory_size` | `/data/tmp`, 80 GB | `/data/tmp`, 80 GB | Large joins and sorts spill to ephemeral storage |
| `preserve_insertion_order` | false | false | Lets DuckDB parallelize scans and writes more |
| `parquet_metadata_cache`, `enable_http_metadata_cache`, `enable_external_file_cache` | true | true | Repeated queries skip S3 round trips |
| `autoinstall_known_extensions`, `allow_community_extensions`, `allow_unsigned_extensions` | false | false | Only the signed core extensions baked into the image |
| `http_timeout`, `http_retries` | 60 s, 5 | 60 s, 5 | Resilient object storage access |

The loader writes Iceberg **V2** tables (readable by Amazon Athena too), ZSTD-compressed,
256 MiB target files, with fact tables sorted by their date key so date filters prune files.

## Prerequisites

- An AWS account and credentials with administrator access for the deployment
  (`aws sts get-caller-identity` must work; `export AWS_PROFILE=...` if you use profiles).
- A Region that offers [Amazon S3 Tables](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-regions-quotas.html)
  and [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html#vpc-origins-supported-regions).
- Local tools: [uv](https://docs.astral.sh/uv/), Terraform ≥ 1.10, Docker with `buildx`
  (builds `linux/arm64` images; native on Apple silicon), Node.js ≥ 20 with npm.

## Deploy

```bash
cd duckdb-s3tables-demo

# 1. Configure: Region, admin email and the public IPs allowed to open the UI
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
curl -s https://checkip.amazonaws.com          # your current public IP
$EDITOR terraform/terraform.tfvars

# 2. Deploy (about 15-20 minutes; CloudFront takes most of it)
uv run duckdemo deploy
```

`deploy` runs in two stages so the UI is never reachable without the login:

1. Builds and unit-tests the Lambda@Edge function, then `terraform apply` creates
   everything with the UI service at **0 tasks**.
2. `verify-gate` requests the CloudFront URL anonymously and requires a redirect to Cognito
   (or a WAF 403). It stops if anything else comes back.
3. Builds the two images for `linux/arm64`, pushes them to ECR with content-hash tags,
   applies again to start the UI task, waits for it to be healthy and checks the gate again.

Terraform asks for confirmation on each apply; `uv run duckdemo deploy -y` skips it.

## Load TPC-DS (SF10)

```bash
uv run duckdemo load-tpcds        # about 2-5 minutes, logs stream to your terminal
uv run duckdemo status            # 24 of 24 tables
```

The loader runs as a one-off Fargate task: `CALL dsdgen(sf = 10)` into a local DuckDB file,
then `CREATE TABLE` + `INSERT` into S3 Tables for each table (S3 Tables doesn't support the
`stage-create` call that `CREATE TABLE AS` needs), and checks row counts. Options:
`--scale-factor 1` for a quick test, `--format-version 3` for Iceberg V3 (Athena can't read V3),
`--replace` to reload.

## Use the demo

1. Open the `ui_url` printed by `deploy` (or `terraform -chdir=terraform output ui_url`).
2. Sign in with the admin email and the temporary password from the Cognito email, and set a
   new password. With `mfa_configuration = "OPTIONAL"` you can enrol an authenticator app.
3. Open **Notebooks → "TPC-DS on Amazon S3 Tables (start here)"**. The 14 cells cover:
   engine settings; the attached catalog; the 24 tables and fact table row counts; Iceberg
   snapshots, data files and table properties; TPC-DS query 3; a pivoted revenue chart;
   file pruning; the 99 built-in TPC-DS queries (`tpcds_queries()`); and a `MERGE INTO`
   followed by time travel on a table in the `sandbox` namespace.
4. Sign out at `/_auth/signout`.

The UI task can **read every table** but can only **create or change tables in `sandbox`**
(IAM condition on `s3tables:namespace`), so the TPC-DS data can't be modified from the UI.

Notebooks live on the task's ephemeral storage. The example notebook is re-created when a
new task starts; notebooks you write yourself are lost when the task is replaced
(see "Going to production").

## Operate

| Command | What it does |
|---|---|
| `uv run duckdemo status` | URL, running tasks, loaded tables |
| `uv run duckdemo scale 0` / `scale 1` | Stop or start the UI task (stop it to save the Fargate cost) |
| `uv run duckdemo verify-gate` | Re-check that anonymous requests are rejected |
| `uv run duckdemo local-ui` | Run both containers locally on `127.0.0.1:18080` with an in-memory TPC-DS SF0.01 (no AWS) |
| `uv run duckdemo deploy` | Apply changes; images are rebuilt only when their sources change |

To allow another client IP, add it to `allowed_cidrs` and run `uv run duckdemo deploy`.
To add users: Cognito console → user pool `duckdemo-users` → **Create user**.

Logs (CloudWatch Logs, 30 days): `/duckdemo/duckdb-ui`, `/duckdemo/proxy`,
`/duckdemo/tpcds-loader`, `/duckdemo/vpc-flow-logs`; WAF requests in `aws-waf-logs-duckdemo`
(us-east-1, cookies redacted); Lambda@Edge in `/aws/lambda/us-east-1.duckdemo-edge-auth`
in the Region closest to the viewer.

## Costs (rough, us-east-1/eu-west-1 on-demand)

| Item | Approx. |
|---|---|
| UI task, 8 vCPU / 32 GiB ARM64, running | ~$0.33 / hour |
| Loader, 16 vCPU / 64 GiB, ~5 min once | ~$0.10 |
| NAT gateway | ~$0.045 / hour + data |
| Interface endpoints (5 × 2 AZs) | ~$0.10 / hour |
| Internal ALB | ~$0.025 / hour |
| S3 Tables storage for SF10 (~3-4 GB Parquet) + maintenance | < $1 / month |
| WAF, CloudFront, Cognito (Essentials, 1 user), Lambda@Edge | a few dollars / month |

Roughly **$0.50 / hour while the UI runs**; `scale 0` drops it to about $0.17 / hour.
`destroy` removes everything.

## Clean up

```bash
uv run duckdemo destroy
```

This first deletes every table in the table bucket (S3 Tables namespaces can only be
deleted when empty), then runs `terraform destroy`. Lambda@Edge replicas take 15-60
minutes to clear after the distribution is deleted: if Terraform reports that the function
is "a replicated function", wait and run `destroy` again.

Two log groups are created by AWS outside Terraform and are not removed by `destroy`:
`/aws/lambda/us-east-1.duckdemo-edge-auth` (in the Regions where the edge function ran) and
`/aws/ecs/containerinsights/duckdemo/performance`. Delete them in the CloudWatch console
if you want a fully clean account.

## Security notes

What is in place:

- **No public origin.** The ALB is internal; only the CloudFront VPC origin can reach it
  (security group allows the CloudFront origin-facing prefix list only). Tasks have no public IP.
- **Two gates in front of the SQL console.** AWS WAF blocks every IP outside `allowed_cidrs`
  (`0.0.0.0/0` is rejected by validation), plus a per-IP rate limit and the AWS IP reputation
  and known-bad-inputs rule groups. Then Lambda@Edge requires a Cognito session: OAuth code
  flow with a confidential client, signed CSRF nonce, `Secure; HttpOnly; SameSite=Lax` cookies,
  ID token verified on every request. If the edge function can't load its configuration it
  answers 503 (fail closed).
- **The DuckDB UI's localhost-only design is kept as far as possible.** The UI binds to
  loopback; the proxy sidecar is the only path to it. The UI rejects cross-origin requests,
  and the proxy keeps that check for the real public origin before rewriting `Host`/`Origin`.
  It also strips the Cognito cookies so DuckDB never sees them.
- **Least privilege.** UI role: read all tables, write only in `sandbox`. Loader role: write
  in the demo bucket only. Execution role: pull from the two repositories and write to
  the three log groups. No `*` actions on data.
- **Supply chain.** Pinned DuckDB 2.0.0 (uv lock), signed core extensions baked into the
  image, extension auto-install and unsigned/community extensions disabled, immutable ECR
  tags with scan on push, non-root containers with a read-only root filesystem.
- **Egress.** AWS APIs through VPC endpoints; DNS Firewall resolves only AWS names and
  `ui.duckdb.org`. This is a guard rail: a query that uses a literal IP address can still
  reach the internet on 443.

Known trade-offs of this demo, and what to change for production:

- **Anyone who signs in can run any SQL** with the UI task role (read all TPC-DS tables, write
  in `sandbox`, read local files in the container). Give the UI only to trusted users, or put
  a governed SQL layer in front for wider audiences.
- **CloudFront → ALB is HTTP** inside the VPC origin, and the viewer side uses the default
  `*.cloudfront.net` certificate. With a domain: ACM certificates, an HTTPS listener on the ALB,
  `origin_protocol_policy = "https-only"` and `minimum_protocol_version = "TLSv1.2_2021"`.
- **AWS managed encryption keys** everywhere. Use customer managed KMS keys if your policies
  require key control or separation (S3 Tables needs a key policy for
  `maintenance.s3tables.amazonaws.com`).
- **Single task, ephemeral notebooks.** Mount Amazon EFS at `/data/home` to keep user notebooks,
  and add Lake Formation through the AWS Glue Iceberg REST endpoint for fine-grained access.
- **Hard egress control** needs AWS Network Firewall or a proxy with a domain allow list,
  instead of DNS Firewall alone.
- **MFA**: set `mfa_configuration = "ON"`. **Terraform state** contains the Cognito client
  secret: use an encrypted S3 backend with restricted access instead of local state.
- `checkov`/`trivy` will flag the items above (HTTP listener, default certificate, AWS managed
  keys, 30-day log retention, no ALB/CloudFront access logs). They are deliberate for a demo;
  WAF logs record every request.

## Repository layout

```
duckdb-s3tables-demo/
├── pyproject.toml, uv.lock        # the `duckdemo` CLI (uv)
├── src/duckdemo/cli.py
├── terraform/                     # all infrastructure
│   ├── network.tf  endpoints.tf  dns_firewall.tf
│   ├── s3tables.tf ecr.tf iam.tf ecs.tf alb.tf
│   ├── cognito.tf  edge.tf waf.tf cloudfront.tf
│   └── terraform.tfvars.example
├── images/
│   ├── duckdb/                    # DuckDB 2.0 image (uv-locked), UI server, TPC-DS loader
│   │   └── app/notebooks/tpcds_on_s3_tables.sql   # the example notebook
│   └── proxy/                     # HAProxy sidecar
└── edge-auth/                     # Lambda@Edge Cognito gate (cognito-at-edge) + tests
```

### Add your own notebook

Drop a `.sql` file into `images/duckdb/app/notebooks/`: a `-- @title ...` line, then cells
separated by `-- @cell`. `{{db}}` expands to `lake.tpcds`, `{{lake}}` to `lake`. Run
`uv run duckdemo deploy` and the next task seeds it.

## License

Apache License 2.0. See [LICENSE](LICENSE).

The image bundles [DuckDB](https://duckdb.org) (MIT) and its core extensions; the edge function bundles [cognito-at-edge](https://github.com/awslabs/cognito-at-edge) (Apache 2.0). The DuckDB UI frontend is served by MotherDuck from ui.duckdb.org at runtime under its own terms.
