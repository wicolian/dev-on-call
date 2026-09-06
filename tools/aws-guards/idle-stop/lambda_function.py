"""
idle-stop
=========

Stops any EC2 instance in the account that has done nothing for 3 hours, so a
colleague's box left running overnight does not eat the credits.

It runs hourly and, in every enabled region, looks at every `running` instance:

  * tagged `AutoStop=off`             -> skipped, never stopped
  * listed in SKIP_INSTANCE_IDS       -> skipped; e.g. a box with its own
                                        input-based idle rule inside the OS
  * launched less than 3 hours ago    -> skipped, there is not enough history

For the rest it pulls 3 hours of CloudWatch at a 5-minute period and calls the
box idle only when all three are true:

    average CPUUtilization  <  3 %      over the whole window
    maximum CPUUtilization  < 15 %      over the whole window
    every 5-minute NetworkPacketsIn sum < 3000 packets

The packet bar is the one that stops false positives. SSH keepalives and
Tailscale/DERP chatter sit at a few hundred packets per 5 minutes; a real
session, an rsync or a package download is tens of thousands. So an idle box
with a live SSH window still counts as idle, and a box quietly downloading a
dataset at 1 % CPU does not.

Idle instances are **stopped, never terminated**, and tagged
`AutoStopped=<iso timestamp>` so it is obvious later why a box is off. One SNS
summary is sent per run listing what was stopped, with the Name and Owner tags.

Event options (all optional):
    {"dry_run": true}         - list what would be stopped, stop nothing,
                                tag nothing, send no email
    {"IDLE_HOURS": 3}         - window length
    {"CPU_AVG_MAX": 3}        - average CPU bar, percent
    {"CPU_PEAK_MAX": 15}      - peak CPU bar, percent
    {"PACKETS_MAX": 3000}     - per-5-minute NetworkPacketsIn bar
    {"regions": ["us-east-1"]} - only look at these regions
"""

import datetime as dt
import json
import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

ACCOUNT_ID = os.environ.get("ACCOUNT_ID", "123456789012")
HOME_REGION = os.environ.get("HOME_REGION", "us-east-1")

# Name this function is deployed as — only used for log/email text.
FUNCTION_NAME = os.environ.get("FUNCTION_NAME", "idle-stop")

TOPIC_NAME = os.environ.get("TOPIC_NAME", "spend-guard-alerts")
TOPIC_ARN = os.environ.get(
    "TOPIC_ARN", f"arn:aws:sns:{HOME_REGION}:{ACCOUNT_ID}:{TOPIC_NAME}"
)

# Idle definition.
DEFAULT_IDLE_HOURS = float(os.environ.get("IDLE_HOURS", "3"))
DEFAULT_CPU_AVG_MAX = float(os.environ.get("CPU_AVG_MAX", "3"))
DEFAULT_CPU_PEAK_MAX = float(os.environ.get("CPU_PEAK_MAX", "15"))
DEFAULT_PACKETS_MAX = float(os.environ.get("PACKETS_MAX", "3000"))

PERIOD = int(os.environ.get("PERIOD", "300"))  # 5 minutes, EC2 basic monitoring

# Do not judge a box on a handful of datapoints. 3 h at 300 s = 36 expected.
MIN_DATAPOINTS = int(os.environ.get("MIN_DATAPOINTS", "30"))

# Instances carrying this exact tag are never stopped.
EXEMPT_TAG_KEY = os.environ.get("EXEMPT_TAG_KEY", "AutoStop")
EXEMPT_TAG_VALUE = os.environ.get("EXEMPT_TAG_VALUE", "off")

# Tag written onto anything this function stops.
STOPPED_TAG_KEY = os.environ.get("STOPPED_TAG_KEY", "AutoStopped")

# Instances this function must never touch, whatever their tags say.
# Empty by default — set SKIP_INSTANCE_IDS (comma separated) per deployment.
SKIP_INSTANCE_IDS = {
    i.strip()
    for i in os.environ.get("SKIP_INSTANCE_IDS", "").split(",")
    if i.strip()
}

# GetMetricData takes 500 queries per call; 3 queries per instance.
INSTANCES_PER_BATCH = 150

BOTO_CFG = Config(
    retries={"max_attempts": 5, "mode": "standard"},
    connect_timeout=10,
    read_timeout=30,
)

sns = boto3.client("sns", region_name=HOME_REGION, config=BOTO_CFG)


def log(msg):
    print(msg, flush=True)


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def tag_value(instance, key):
    for tag in instance.get("Tags", []):
        if tag.get("Key") == key:
            return tag.get("Value")
    return None


# --------------------------------------------------------------------------
# Regions and instances
# --------------------------------------------------------------------------


def enabled_regions():
    ec2 = boto3.client("ec2", region_name=HOME_REGION, config=BOTO_CFG)
    regions = ec2.describe_regions(AllRegions=True)["Regions"]
    return sorted(
        r["RegionName"] for r in regions if r.get("OptInStatus") != "not-opted-in"
    )


def running_instances(ec2):
    out = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for res in page.get("Reservations", []):
            out.extend(res.get("Instances", []))
    return out


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------


def _query(qid, instance_id, metric_name, stat):
    return {
        "Id": qid,
        "MetricStat": {
            "Metric": {
                "Namespace": "AWS/EC2",
                "MetricName": metric_name,
                "Dimensions": [{"Name": "InstanceId", "Value": instance_id}],
            },
            "Period": PERIOD,
            "Stat": stat,
        },
        "ReturnData": True,
    }


def fetch_metrics(cw, instance_ids, start, end):
    """{instance_id: {"cpu_avg": [...], "cpu_max": [...], "pkts": [...]}}"""
    series = {
        iid: {"cpu_avg": [], "cpu_max": [], "pkts": []} for iid in instance_ids
    }
    index = {}
    queries = []
    for n, iid in enumerate(instance_ids):
        for suffix, metric, stat, key in (
            ("a", "CPUUtilization", "Average", "cpu_avg"),
            ("b", "CPUUtilization", "Maximum", "cpu_max"),
            ("c", "NetworkPacketsIn", "Sum", "pkts"),
        ):
            qid = f"m{n}{suffix}"
            index[qid] = (iid, key)
            queries.append(_query(qid, iid, metric, stat))

    paginator = cw.get_paginator("get_metric_data")
    for page in paginator.paginate(
        MetricDataQueries=queries,
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampAscending",
    ):
        for result in page.get("MetricDataResults", []):
            iid, key = index[result["Id"]]
            series[iid][key].extend(result.get("Values", []))
    return series


def judge(inst, series, thresholds, min_launch_time):
    """Return (is_idle, detail_dict). detail explains the verdict either way."""
    iid = inst["InstanceId"]
    launch = inst["LaunchTime"]
    detail = {
        "instance_id": iid,
        "region": inst["_region"],
        "name": tag_value(inst, "Name"),
        "owner": tag_value(inst, "Owner"),
        "instance_type": inst.get("InstanceType"),
        "launch_time": launch.isoformat(),
    }

    if launch > min_launch_time:
        detail["verdict"] = "too_young"
        detail["reason"] = (
            f"launched {launch.isoformat()}, less than "
            f"{thresholds['idle_hours']} h ago"
        )
        return False, detail

    cpu_avg = series[iid]["cpu_avg"]
    cpu_max = series[iid]["cpu_max"]
    pkts = series[iid]["pkts"]
    detail["datapoints"] = {
        "cpu_avg": len(cpu_avg),
        "cpu_max": len(cpu_max),
        "packets": len(pkts),
    }

    if len(cpu_avg) < thresholds["min_datapoints"]:
        detail["verdict"] = "not_enough_data"
        detail["reason"] = (
            f"{len(cpu_avg)} CPU datapoints, need {thresholds['min_datapoints']}"
        )
        return False, detail

    mean_cpu = sum(cpu_avg) / len(cpu_avg)
    peak_cpu = max(cpu_max) if cpu_max else 0.0
    peak_pkts = max(pkts) if pkts else 0.0
    detail["cpu_avg_pct"] = round(mean_cpu, 3)
    detail["cpu_peak_pct"] = round(peak_cpu, 3)
    detail["packets_in_peak_per_period"] = round(peak_pkts, 1)

    reasons = []
    if mean_cpu >= thresholds["cpu_avg_max"]:
        reasons.append(
            f"average CPU {mean_cpu:.2f}% >= {thresholds['cpu_avg_max']}%"
        )
    if peak_cpu >= thresholds["cpu_peak_max"]:
        reasons.append(f"peak CPU {peak_cpu:.2f}% >= {thresholds['cpu_peak_max']}%")
    if peak_pkts >= thresholds["packets_max"]:
        reasons.append(
            f"a 5-minute NetworkPacketsIn sum reached {peak_pkts:.0f} "
            f">= {thresholds['packets_max']:.0f}"
        )

    if reasons:
        detail["verdict"] = "busy"
        detail["reason"] = "; ".join(reasons)
        return False, detail

    detail["verdict"] = "idle"
    detail["reason"] = (
        f"average CPU {mean_cpu:.2f}%, peak CPU {peak_cpu:.2f}%, busiest "
        f"5-minute packets-in {peak_pkts:.0f} - all under the bars for "
        f"{thresholds['idle_hours']} h"
    )
    return True, detail


# --------------------------------------------------------------------------
# Per-region sweep
# --------------------------------------------------------------------------


def sweep_region(region, thresholds, start, end, min_launch_time, dry_run):
    ec2 = boto3.client("ec2", region_name=region, config=BOTO_CFG)
    cw = boto3.client("cloudwatch", region_name=region, config=BOTO_CFG)
    result = {
        "region": region,
        "running": 0,
        "stopped": [],
        "skipped": [],
        "kept_running": [],
        "errors": [],
    }

    try:
        instances = running_instances(ec2)
    except ClientError as exc:
        result["errors"].append(f"describe_instances: {exc}")
        return result

    result["running"] = len(instances)
    candidates = []
    for inst in instances:
        inst["_region"] = region
        iid = inst["InstanceId"]
        if iid in SKIP_INSTANCE_IDS:
            result["skipped"].append(
                {"instance_id": iid, "why": "on the never-touch list"}
            )
            continue
        if tag_value(inst, EXEMPT_TAG_KEY) == EXEMPT_TAG_VALUE:
            result["skipped"].append(
                {
                    "instance_id": iid,
                    "name": tag_value(inst, "Name"),
                    "why": f"tagged {EXEMPT_TAG_KEY}={EXEMPT_TAG_VALUE}",
                }
            )
            continue
        candidates.append(inst)

    if not candidates:
        return result

    idle = []
    for i in range(0, len(candidates), INSTANCES_PER_BATCH):
        chunk = candidates[i : i + INSTANCES_PER_BATCH]
        try:
            series = fetch_metrics(cw, [c["InstanceId"] for c in chunk], start, end)
        except ClientError as exc:
            result["errors"].append(f"get_metric_data: {exc}")
            continue
        for inst in chunk:
            is_idle, detail = judge(inst, series, thresholds, min_launch_time)
            if is_idle:
                idle.append(detail)
            else:
                result["kept_running"].append(detail)

    if not idle:
        return result

    ids = [d["instance_id"] for d in idle]
    stamp = now_utc().replace(microsecond=0).isoformat()
    if not dry_run:
        try:
            ec2.stop_instances(InstanceIds=ids)
        except ClientError as exc:
            result["errors"].append(f"stop_instances {ids}: {exc}")
            return result
        try:
            ec2.create_tags(
                Resources=ids, Tags=[{"Key": STOPPED_TAG_KEY, "Value": stamp}]
            )
        except ClientError as exc:
            result["errors"].append(f"create_tags {ids}: {exc}")

    for d in idle:
        d["stopped_at"] = stamp
    result["stopped"] = idle
    return result


# --------------------------------------------------------------------------
# Email
# --------------------------------------------------------------------------


def publish(subject, body, dry_run):
    if dry_run:
        log(f"DRY RUN would publish SNS: {subject}\n{body}")
        return False
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=body)
    return True


def summary_body(stopped, thresholds, sweeps):
    lines = [
        f"{FUNCTION_NAME} stopped {len(stopped)} idle EC2 "
        f"{'instance' if len(stopped) == 1 else 'instances'} in account "
        f"{ACCOUNT_ID}.",
        "",
        "Idle means, for the last {h} hours: average CPU under {a}%, peak CPU "
        "under {p}%, and no 5-minute period with {k} or more inbound "
        "packets.".format(
            h=thresholds["idle_hours"],
            a=thresholds["cpu_avg_max"],
            p=thresholds["cpu_peak_max"],
            k=int(thresholds["packets_max"]),
        ),
        "",
    ]
    for d in stopped:
        lines.append(f"  {d['instance_id']}  ({d['region']}, {d['instance_type']})")
        lines.append(f"    Name:  {d.get('name') or '-'}")
        lines.append(f"    Owner: {d.get('owner') or '-'}")
        lines.append(
            f"    avg CPU {d['cpu_avg_pct']}%, peak CPU {d['cpu_peak_pct']}%, "
            f"busiest 5-min packets-in {d['packets_in_peak_per_period']:.0f}"
        )
        lines.append(f"    tagged AutoStopped={d['stopped_at']}")
        lines.append("")

    lines.append("Nothing was terminated. Start a box again with:")
    lines.append("")
    lines.append(
        "  aws ec2 start-instances --instance-ids <id> --region <region>"
    )
    lines.append("")
    lines.append("To make a box exempt for good:")
    lines.append("")
    lines.append(
        "  aws ec2 create-tags --resources <id> --region <region> "
        "--tags Key=AutoStop,Value=off"
    )

    errors = [(s["region"], e) for s in sweeps for e in s["errors"]]
    if errors:
        lines.append("")
        lines.append("Errors during this run:")
        for region, err in errors:
            lines.append(f"  {region}: {err}")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Handler
# --------------------------------------------------------------------------


def lambda_handler(event, context):
    event = event or {}
    dry_run = bool(event.get("dry_run", False))

    thresholds = {
        "idle_hours": float(event.get("IDLE_HOURS", DEFAULT_IDLE_HOURS)),
        "cpu_avg_max": float(event.get("CPU_AVG_MAX", DEFAULT_CPU_AVG_MAX)),
        "cpu_peak_max": float(event.get("CPU_PEAK_MAX", DEFAULT_CPU_PEAK_MAX)),
        "packets_max": float(event.get("PACKETS_MAX", DEFAULT_PACKETS_MAX)),
        "min_datapoints": int(event.get("MIN_DATAPOINTS", MIN_DATAPOINTS)),
    }

    end = now_utc().replace(second=0, microsecond=0)
    start = end - dt.timedelta(hours=thresholds["idle_hours"])
    min_launch_time = start

    regions = event.get("regions") or enabled_regions()
    log(
        f"{FUNCTION_NAME} dry_run={dry_run} window={start.isoformat()}.."
        f"{end.isoformat()} thresholds={thresholds} regions={len(regions)}"
    )

    sweeps = []
    for region in regions:
        try:
            sweeps.append(
                sweep_region(
                    region, thresholds, start, end, min_launch_time, dry_run
                )
            )
        except ClientError as exc:
            sweeps.append(
                {
                    "region": region,
                    "running": 0,
                    "stopped": [],
                    "skipped": [],
                    "kept_running": [],
                    "errors": [str(exc)],
                }
            )

    stopped = [d for s in sweeps for d in s["stopped"]]
    report = {
        "checked_at": end.isoformat(),
        "dry_run": dry_run,
        "window_start": start.isoformat(),
        "window_end": end.isoformat(),
        "thresholds": thresholds,
        "regions_checked": regions,
        "running_total": sum(s["running"] for s in sweeps),
        "stopped_count": len(stopped),
        "stopped": stopped,
        "skipped": [d for s in sweeps for d in s["skipped"]],
        "kept_running": [d for s in sweeps for d in s["kept_running"]],
        "errors": [
            {"region": s["region"], "error": e} for s in sweeps for e in s["errors"]
        ],
        "email_sent": False,
    }

    if stopped:
        report["email_sent"] = publish(
            f"[{FUNCTION_NAME}] stopped {len(stopped)} idle EC2 "
            f"{'instance' if len(stopped) == 1 else 'instances'}",
            summary_body(stopped, thresholds, sweeps),
            dry_run,
        )

    log(json.dumps(report, default=str))
    return report
