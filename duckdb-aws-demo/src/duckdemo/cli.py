"""duckdemo: deploy and operate the DuckDB 2.0 + Amazon S3 Tables demo.

    uv run duckdemo deploy          # infrastructure, login gate check, images, service
    uv run duckdemo load-tpcds      # generate TPC-DS SF10 and load it into S3 Tables
    uv run duckdemo verify-gate     # prove anonymous requests can't reach the UI
    uv run duckdemo status
    uv run duckdemo scale 0|1       # stop or start the UI task
    uv run duckdemo local-ui        # run the containers on this machine (no AWS)
    uv run duckdemo destroy

AWS credentials come from the usual chain (AWS_PROFILE, SSO, environment).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TF_DIR = ROOT / "terraform"
EDGE_DIR = ROOT / "edge-auth"
IMAGES_DIR = ROOT / "images"
IMAGES_TFVARS = TF_DIR / "images.auto.tfvars.json"


# --- helpers -----------------------------------------------------------------------------

def info(msg: str) -> None:
    print(f"\033[1;36m==>\033[0m {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"\033[1;31mERROR:\033[0m {msg}", file=sys.stderr)
    raise SystemExit(1)


def run(cmd: list[str], cwd: Path | None = None, capture: bool = False, stdin: str | None = None) -> str:
    try:
        res = subprocess.run(cmd, cwd=cwd, check=True, text=True, input=stdin,
                             stdout=subprocess.PIPE if capture else None)
    except FileNotFoundError:
        fail(f"'{cmd[0]}' is not installed or not on PATH")
    except subprocess.CalledProcessError as exc:
        fail(f"command failed ({exc.returncode}): {' '.join(cmd)}")
    return res.stdout if capture else ""


def require_tools(*tools: str) -> None:
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        fail(f"missing tools: {', '.join(missing)} (see README prerequisites)")


def tf(*args: str, capture: bool = False) -> str:
    return run(["terraform", f"-chdir={TF_DIR}", *args], capture=capture)


def tf_outputs() -> dict:
    raw = tf("output", "-json", capture=True)
    out = {k: v["value"] for k, v in json.loads(raw or "{}").items()}
    if not out:
        fail("no Terraform outputs yet; run `uv run duckdemo deploy` first")
    return out


def session(region: str):
    import boto3
    return boto3.session.Session(region_name=region)


def context_hash(path: Path) -> str:
    """Content hash of a Docker build context: identical sources give identical, immutable tags."""
    h = hashlib.sha256()
    for f in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = f.relative_to(path)
        if any(part in {".venv", "__pycache__"} for part in rel.parts) or f.suffix in {".pyc", ".duckdb", ".wal"}:
            continue
        h.update(str(rel).encode())
        h.update(f.read_bytes())
    return h.hexdigest()[:16]


def http(url: str, method: str = "GET", headers: dict | None = None) -> tuple[int, dict]:
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, method=method, headers=headers or {},
                                 data=b"SELECT 1" if method == "POST" else None)
    try:
        with opener.open(req, timeout=20) as resp:
            return resp.status, dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers)


# --- commands ----------------------------------------------------------------------------

def build_edge() -> None:
    require_tools("npm")
    info("building the Lambda@Edge login function")
    run(["npm", "ci", "--no-audit", "--no-fund", "--loglevel=error"], cwd=EDGE_DIR)
    run(["npm", "test", "--silent"], cwd=EDGE_DIR)
    run(["npm", "run", "-s", "build"], cwd=EDGE_DIR)


def cmd_verify_gate(_args=None) -> None:
    """Anonymous requests must be stopped by the WAF (403) or redirected to Cognito (302)."""
    out = tf_outputs()
    base, cognito = out["ui_url"], out["cognito_domain"]
    info(f"checking that {base} rejects anonymous requests")
    failures = []
    for method, path in [("GET", "/"), ("GET", "/notebooks"), ("POST", "/ddb/run"), ("GET", "/localEvents")]:
        headers = {"Origin": base} if method == "POST" else {}
        status, hdrs = http(base + path, method, headers)
        location = hdrs.get("Location", hdrs.get("location", ""))
        if status == 302 and cognito in location:
            verdict = "OK  redirected to Cognito sign-in"
        elif status == 403:
            verdict = "OK  blocked by AWS WAF (this IP is not in allowed_cidrs)"
        else:
            verdict = f"FAIL got {status} {location}".rstrip()
            failures.append(path)
        print(f"   {method:4} {path:14} -> {status}  {verdict}")
    if failures:
        fail("the UI is reachable without signing in; do not use this deployment until fixed")
    info("login gate verified: anonymous requests can't reach the DuckDB UI")


def push_images(out: dict) -> dict[str, str]:
    require_tools("docker")
    region = out["region"]
    ecr = session(region).client("ecr")
    auth = ecr.get_authorization_token()["authorizationData"][0]
    user, password = base64.b64decode(auth["authorizationToken"]).decode().split(":", 1)
    registry = auth["proxyEndpoint"].removeprefix("https://")
    run(["docker", "login", "--username", user, "--password-stdin", registry], stdin=password, capture=True)

    tags = {}
    for name in ("duckdb", "proxy"):
        repo = out["ecr_repositories"][name]
        tag = context_hash(IMAGES_DIR / name)
        repo_name = repo.split("/", 1)[1]
        try:
            ecr.describe_images(repositoryName=repo_name, imageIds=[{"imageTag": tag}])
            info(f"{name}: image {tag} already in ECR")
        except ecr.exceptions.ImageNotFoundException:
            info(f"{name}: building and pushing {repo}:{tag} (linux/arm64)")
            run(["docker", "buildx", "build", "--platform", "linux/arm64", "--provenance=false",
                 "-t", f"{repo}:{tag}", "--push", str(IMAGES_DIR / name)])
        tags[f"{name}_image_tag"] = tag
    return tags


def wait_for_service(out: dict) -> None:
    ecs = session(out["region"]).client("ecs")
    info("waiting for the DuckDB UI task to become healthy (a few minutes)")
    ecs.get_waiter("services_stable").wait(
        cluster=out["ecs_cluster"], services=[out["ui_service"]],
        WaiterConfig={"Delay": 15, "MaxAttempts": 60},
    )


def cmd_deploy(args) -> None:
    require_tools("terraform", "npm", "docker")
    if not (TF_DIR / "terraform.tfvars").exists():
        fail("create terraform/terraform.tfvars from terraform/terraform.tfvars.example first")
    build_edge()
    tf("init", "-input=false", "-upgrade=false")

    # Stage 1: everything, with the UI service at 0 tasks (no image yet). The login gate
    # is checked before any DuckDB task can serve traffic.
    first_run = not IMAGES_TFVARS.exists()
    if first_run:
        info("stage 1/2: infrastructure, login gate and empty origin")
        tf("apply", "-input=false", *(["-auto-approve"] if args.yes else []))
        cmd_verify_gate()

    out = tf_outputs()
    tags = push_images(out)
    IMAGES_TFVARS.write_text(json.dumps(tags, indent=2) + "\n")

    info("stage 2/2: start the DuckDB UI service with the pushed images")
    tf("apply", "-input=false", *(["-auto-approve"] if args.yes else []))
    out = tf_outputs()
    wait_for_service(out)
    cmd_verify_gate()
    print()
    info(f"DuckDB UI: {out['ui_url']}")
    info(f"Sign in as {out['admin_username']} with the temporary password Cognito emailed you.")
    info("Next: uv run duckdemo load-tpcds   (about 2-5 minutes for SF10)")


def cmd_load(args) -> None:
    out = tf_outputs()
    if not out.get("images_ready"):
        fail("images are not pushed yet; run `uv run duckdemo deploy` first")
    s = session(out["region"])
    ecs, logs = s.client("ecs"), s.client("logs")
    command = ["python", "-m", "app.load_tpcds", "--scale-factor", str(args.scale_factor),
               "--format-version", args.format_version] + (["--replace"] if args.replace else [])
    info(f"starting the TPC-DS loader (SF{args.scale_factor}, Iceberg V{args.format_version})")
    task = ecs.run_task(
        cluster=out["ecs_cluster"],
        taskDefinition=out["loader_task_definition"],
        launchType="FARGATE",
        networkConfiguration={"awsvpcConfiguration": {
            "subnets": out["private_subnet_ids"],
            "securityGroups": [out["task_security_group_id"]],
            "assignPublicIp": "DISABLED",
        }},
        overrides={"containerOverrides": [{"name": "loader", "command": command}]},
        startedBy="duckdemo-cli",
    )
    if task.get("failures"):
        fail(f"run_task failed: {task['failures']}")
    task_arn = task["tasks"][0]["taskArn"]
    task_id = task_arn.rsplit("/", 1)[1]
    stream = f"loader/loader/{task_id}"
    info(f"task {task_id}; streaming logs from {out['loader_log_group']}")

    token, status = None, "PENDING"
    while True:
        desc = ecs.describe_tasks(cluster=out["ecs_cluster"], tasks=[task_arn])["tasks"][0]
        status = desc["lastStatus"]
        try:
            kw = {"logGroupName": out["loader_log_group"], "logStreamName": stream, "startFromHead": True}
            if token:
                kw["nextToken"] = token
            page = logs.get_log_events(**kw)
            for e in page["events"]:
                print("   ", e["message"])
            token = page["nextForwardToken"]
        except logs.exceptions.ResourceNotFoundException:
            pass
        if status == "STOPPED":
            break
        time.sleep(10)
    code = desc["containers"][0].get("exitCode")
    if code != 0:
        fail(f"loader stopped with exit code {code}: {desc.get('stoppedReason', '')}")
    info("TPC-DS loaded. Open the UI and run the 'TPC-DS on Amazon S3 Tables' notebook.")


def cmd_status(_args) -> None:
    out = tf_outputs()
    s = session(out["region"])
    svc = s.client("ecs").describe_services(cluster=out["ecs_cluster"], services=[out["ui_service"]])["services"][0]
    tables = s.client("s3tables").list_tables(tableBucketARN=out["table_bucket_arn"],
                                              namespace=out["tpcds_namespace"]).get("tables", [])
    print(f"UI URL         {out['ui_url']}")
    print(f"UI tasks       running {svc['runningCount']} / desired {svc['desiredCount']}")
    print(f"TPC-DS tables  {len(tables)} of 24 in {out['tpcds_namespace']}")


def cmd_scale(args) -> None:
    if not IMAGES_TFVARS.exists():
        fail("deploy first")
    data = json.loads(IMAGES_TFVARS.read_text())
    data["ui_desired_count"] = args.count
    IMAGES_TFVARS.write_text(json.dumps(data, indent=2) + "\n")
    tf("apply", "-input=false", *(["-auto-approve"] if args.yes else []))
    if args.count:
        wait_for_service(tf_outputs())
    info(f"UI service desired count is now {args.count}")


def cmd_local_ui(_args) -> None:
    """Both containers on this machine with a tiny in-memory TPC-DS. Bound to 127.0.0.1 only."""
    require_tools("docker")
    for name in ("duckdb", "proxy"):
        run(["docker", "buildx", "build", "--load", "-t", f"duckdemo-{name}:local", str(IMAGES_DIR / name)])
    run(["docker", "rm", "-f", "duckdemo-ui", "duckdemo-proxy"], capture=True)
    hardening = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
    run(["docker", "run", "-d", "--name", "duckdemo-ui", *hardening, "--tmpfs", "/data:uid=10001,gid=10001",
         "-p", "127.0.0.1:18080:8080",
         "-e", "AWS_REGION=eu-west-1",
         "-e", "TABLE_BUCKET_ARN=arn:aws:s3tables:eu-west-1:123456789012:bucket/local-test",
         "-e", "DUCKDB_MEMORY_LIMIT=4GB", "-e", "DUCKDB_THREADS=4", "-e", "DUCKDB_MAX_TEMP_SIZE=2GB",
         "-e", "SKIP_S3TABLES_ATTACH_FOR_LOCAL_TEST=1", "duckdemo-duckdb:local"], capture=True)
    run(["docker", "run", "-d", "--name", "duckdemo-proxy", *hardening, "--network", "container:duckdemo-ui",
         "-e", "PUBLIC_ORIGIN=http://localhost:18080", "duckdemo-proxy:local"], capture=True)
    info("open http://localhost:18080  (stop with: docker rm -f duckdemo-ui duckdemo-proxy)")


def delete_tables(out: dict) -> None:
    """S3 Tables namespaces can only be deleted when empty, so drop the tables first."""
    s3t = session(out["region"]).client("s3tables")
    arn = out["table_bucket_arn"]
    for page in s3t.get_paginator("list_tables").paginate(tableBucketARN=arn):
        for t in page.get("tables", []):
            s3t.delete_table(tableBucketARN=arn, namespace=t["namespace"][0], name=t["name"])
            print(f"   deleted table {t['namespace'][0]}.{t['name']}")


def cmd_destroy(args) -> None:
    require_tools("terraform")
    info("destroying every resource of the demo, including all tables and their data")
    if not args.yes and input("Type 'destroy' to continue: ").strip() != "destroy":
        fail("aborted")
    try:
        out = tf_outputs()
    except SystemExit:
        out = {}
    if out.get("table_bucket_arn"):
        delete_tables(out)
    info("note: Lambda@Edge replicas take 15-60 minutes to clear after CloudFront is gone; "
         "if the function fails to delete, wait and run destroy again")
    tf("destroy", "-input=false", "-auto-approve")
    IMAGES_TFVARS.unlink(missing_ok=True)


def main() -> None:
    p = argparse.ArgumentParser(prog="duckdemo", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    d = sub.add_parser("deploy", help="deploy or update everything")
    d.add_argument("-y", "--yes", action="store_true", help="skip Terraform's apply confirmation")
    d.set_defaults(func=cmd_deploy)

    ld = sub.add_parser("load-tpcds", help="generate TPC-DS and load it into S3 Tables")
    ld.add_argument("--scale-factor", type=float, default=10.0)
    ld.add_argument("--format-version", choices=("2", "3"), default="2")
    ld.add_argument("--replace", action="store_true", help="reload tables that already exist")
    ld.set_defaults(func=cmd_load)

    sub.add_parser("verify-gate", help="check that anonymous requests are rejected").set_defaults(func=cmd_verify_gate)
    sub.add_parser("status", help="show the URL, task count and loaded tables").set_defaults(func=cmd_status)

    sc = sub.add_parser("scale", help="start (1) or stop (0) the UI task")
    sc.add_argument("count", type=int, choices=(0, 1))
    sc.add_argument("-y", "--yes", action="store_true")
    sc.set_defaults(func=cmd_scale)

    sub.add_parser("local-ui", help="run the UI locally with a tiny dataset (no AWS)").set_defaults(func=cmd_local_ui)
    ds = sub.add_parser("destroy", help="delete every resource, including the tables")
    ds.add_argument("-y", "--yes", action="store_true", help="skip the confirmation prompt")
    ds.set_defaults(func=cmd_destroy)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
