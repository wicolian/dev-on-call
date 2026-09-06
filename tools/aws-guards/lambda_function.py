"""
spend-guard
===========

Hard spending stop for an AWS account that runs on a fixed pool of credits.
Every identifier below (account id, region, topic, group/policy names) is
read from the environment — see config.example.json in this directory for
the full list and the deploy section of README.md for how to set them.

It measures *gross* usage since CREDITS_START - the number that actually eats
the credits - by asking Cost Explorer for UnblendedCost with Credit / Refund /
Tax record types filtered OUT. Credits therefore do not mask the real burn.

  gross_spend >= WARN  -> email the owner, once per 100 USD band
  gross_spend >= STOP  -> HARD STOP:
        * stop every running/pending EC2 instance in every enabled region
          (except instances tagged SpendGuard=ignore)
        * cancel every open/active *persistent* spot instance request
        * attach the DenyAllForGuests policy to the configured guest IAM group
        * email the owner with what was stopped and how to unlock

State lives in the SSM parameter named by STATE_PARAM so the warning is not
repeated and the trip is recorded once. While tripped, the instance sweep still
runs every day, so anything someone starts back up gets stopped again.

Event options (all optional):
    {"dry_run": true}   - do everything except stop / cancel / attach / publish
    {"WARN": 3500}      - override the warn threshold for this invocation
    {"STOP": 0}         - override the stop threshold for this invocation
                          (with dry_run, this exercises the stop branch safely)
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

CREDITS_START = os.environ.get("CREDITS_START", "2025-01-01")
CREDITS_END = os.environ.get("CREDITS_END", "2026-12-31")
CREDITS_TOTAL = float(os.environ.get("CREDITS_TOTAL", "5000"))

DEFAULT_WARN = float(os.environ.get("WARN", "3500"))
DEFAULT_STOP = float(os.environ.get("STOP", "4000"))

# Name this function is deployed as — only used to print accurate CLI hints
# in emails/logs (e.g. "update-function-configuration --function-name ...").
FUNCTION_NAME = os.environ.get("FUNCTION_NAME", "spend-guard")

TOPIC_NAME = os.environ.get("TOPIC_NAME", "spend-guard-alerts")
TOPIC_ARN = os.environ.get(
    "TOPIC_ARN", f"arn:aws:sns:{HOME_REGION}:{ACCOUNT_ID}:{TOPIC_NAME}"
)
GUEST_GROUP = os.environ.get("GUEST_GROUP", "aws-guests")
DENY_POLICY_ARN = os.environ.get(
    "DENY_POLICY_ARN", f"arn:aws:iam::{ACCOUNT_ID}:policy/DenyAllForGuests"
)
STATE_PARAM = os.environ.get("STATE_PARAM", "/aws-guards/spend-guard/state")

# One warning per this many dollars above WARN.
WARN_BAND = float(os.environ.get("WARN_BAND", "100"))

# Instances carrying this exact tag are never stopped.
IGNORE_TAG_KEY = "SpendGuard"
IGNORE_TAG_VALUE = "ignore"

BOTO_CFG = Config(
    retries={"max_attempts": 5, "mode": "standard"},
    connect_timeout=10,
    read_timeout=30,
)

ssm = boto3.client("ssm", region_name=HOME_REGION, config=BOTO_CFG)
sns = boto3.client("sns", region_name=HOME_REGION, config=BOTO_CFG)
iam = boto3.client("iam", region_name="us-east-1", config=BOTO_CFG)
ce = boto3.client("ce", region_name="us-east-1", config=BOTO_CFG)


def log(msg):
    print(msg, flush=True)


# --------------------------------------------------------------------------
# Cost
# --------------------------------------------------------------------------

GROSS_FILTER = {
    "Not": {
        "Dimensions": {
            "Key": "RECORD_TYPE",
            "Values": ["Credit", "Refund", "Tax"],
        }
    }
}


def get_gross_spend(today):
    """Return (gross_spend_since_credits_start, this_month_gross, monthly_rows)."""
    end = (today + dt.timedelta(days=1)).isoformat()
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": CREDITS_START, "End": end},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        Filter=GROSS_FILTER,
    )

    total = 0.0
    this_month = 0.0
    rows = []
    month_start = today.replace(day=1).isoformat()

    for period in resp.get("ResultsByTime", []):
        start = period["TimePeriod"]["Start"]
        amount = float(period["Total"]["UnblendedCost"]["Amount"])
        total += amount
        rows.append({"month": start, "gross_usd": round(amount, 4)})
        if start == month_start:
            this_month = amount

    return round(total, 4), round(this_month, 4), rows


# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------


def load_state():
    try:
        raw = ssm.get_parameter(Name=STATE_PARAM)["Parameter"]["Value"]
        return json.loads(raw)
    except ssm.exceptions.ParameterNotFound:
        return {}
    except (ClientError, ValueError) as exc:
        log(f"WARN could not read state ({exc}); starting from empty state")
        return {}


def save_state(state):
    ssm.put_parameter(
        Name=STATE_PARAM,
        Value=json.dumps(state),
        Type="String",
        Overwrite=True,
        Description=f"{FUNCTION_NAME} state: last_warned_at / tripped_at",
    )


# --------------------------------------------------------------------------
# Enforcement
# --------------------------------------------------------------------------


def enabled_regions():
    ec2 = boto3.client("ec2", region_name=HOME_REGION, config=BOTO_CFG)
    regions = ec2.describe_regions(AllRegions=True)["Regions"]
    return sorted(
        r["RegionName"]
        for r in regions
        if r.get("OptInStatus") != "not-opted-in"
    )


def _is_ignored(instance):
    for tag in instance.get("Tags", []):
        if tag.get("Key") == IGNORE_TAG_KEY and tag.get("Value") == IGNORE_TAG_VALUE:
            return True
    return False


def sweep_region(region, dry_run):
    """Stop instances and cancel persistent spot requests in one region."""
    ec2 = boto3.client("ec2", region_name=region, config=BOTO_CFG)
    result = {
        "region": region,
        "instances_stopped": [],
        "instances_ignored": [],
        "spot_requests_cancelled": [],
        "errors": [],
    }

    # ---- EC2 instances -------------------------------------------------
    try:
        paginator = ec2.get_paginator("describe_instances")
        pages = paginator.paginate(
            Filters=[{"Name": "instance-state-name", "Values": ["running", "pending"]}]
        )
        to_stop = []
        for page in pages:
            for reservation in page.get("Reservations", []):
                for inst in reservation.get("Instances", []):
                    iid = inst["InstanceId"]
                    if _is_ignored(inst):
                        result["instances_ignored"].append(iid)
                    else:
                        to_stop.append(iid)

        if to_stop:
            if not dry_run:
                for i in range(0, len(to_stop), 100):
                    chunk = to_stop[i : i + 100]
                    try:
                        ec2.stop_instances(InstanceIds=chunk)
                    except ClientError as exc:
                        result["errors"].append(f"stop_instances {chunk}: {exc}")
            result["instances_stopped"] = to_stop
    except ClientError as exc:
        result["errors"].append(f"describe_instances: {exc}")

    # ---- Persistent spot requests --------------------------------------
    try:
        spot = ec2.describe_spot_instance_requests(
            Filters=[
                {"Name": "state", "Values": ["open", "active"]},
                {"Name": "type", "Values": ["persistent"]},
            ]
        ).get("SpotInstanceRequests", [])
        sirs = [s["SpotInstanceRequestId"] for s in spot]
        if sirs:
            if not dry_run:
                try:
                    ec2.cancel_spot_instance_requests(SpotInstanceRequestIds=sirs)
                except ClientError as exc:
                    result["errors"].append(f"cancel_spot {sirs}: {exc}")
            result["spot_requests_cancelled"] = sirs
    except ClientError as exc:
        result["errors"].append(f"describe_spot_instance_requests: {exc}")

    return result


def lock_guest_group(dry_run):
    """Attach DenyAllForGuests to the configured guest group. Idempotent."""
    try:
        attached = iam.list_attached_group_policies(GroupName=GUEST_GROUP)[
            "AttachedPolicies"
        ]
        already = any(p["PolicyArn"] == DENY_POLICY_ARN for p in attached)
    except ClientError as exc:
        return {"attached": False, "already_attached": None, "error": str(exc)}

    if already:
        return {"attached": True, "already_attached": True, "error": None}
    if dry_run:
        return {"attached": False, "already_attached": False, "error": None}
    try:
        iam.attach_group_policy(GroupName=GUEST_GROUP, PolicyArn=DENY_POLICY_ARN)
        return {"attached": True, "already_attached": False, "error": None}
    except ClientError as exc:
        return {"attached": False, "already_attached": False, "error": str(exc)}


# --------------------------------------------------------------------------
# Email
# --------------------------------------------------------------------------

UNLOCK_CMD = (
    f"aws iam detach-group-policy --group-name {GUEST_GROUP} "
    f"--policy-arn {DENY_POLICY_ARN}"
)


def publish(subject, body, dry_run):
    if dry_run:
        log(f"DRY RUN would publish SNS: {subject}")
        return False
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=body)
    return True


def days_left(today):
    end = dt.date.fromisoformat(CREDITS_END)
    return (end - today).days


def warn_body(gross, month, today, warn, stop):
    return (
        "AWS spend warning for account {acct}.\n\n"
        "Gross usage since {start}: {gross:,.2f} USD\n"
        "This month so far:        {month:,.2f} USD\n"
        "Warn threshold:           {warn:,.2f} USD\n"
        "Hard stop threshold:      {stop:,.2f} USD\n"
        "Credits:                  {total:,.2f} USD, valid to {end}\n"
        "Days of credit validity left: {days}\n\n"
        "This is the number that eats the credits (credits, refunds and tax are "
        "excluded from it).\n\n"
        "At {stop:,.2f} USD the guard stops every EC2 instance in every enabled "
        "region, cancels persistent spot requests, and locks the {group} IAM "
        "group.\n"
    ).format(
        acct=ACCOUNT_ID,
        start=CREDITS_START,
        gross=gross,
        month=month,
        warn=warn,
        stop=stop,
        total=CREDITS_TOTAL,
        end=CREDITS_END,
        days=days_left(today),
        group=GUEST_GROUP,
    )


def stop_body(gross, month, today, stop, sweeps, lock, first_trip):
    lines = []
    lines.append(
        "HARD STOP {} for AWS account {}.".format(
            "TRIPPED" if first_trip else "STILL ACTIVE - re-swept", ACCOUNT_ID
        )
    )
    lines.append("")
    lines.append(f"Gross usage since {CREDITS_START}: {gross:,.2f} USD")
    lines.append(f"This month so far:                {month:,.2f} USD")
    lines.append(f"Hard stop threshold:              {stop:,.2f} USD")
    lines.append(f"Credits: {CREDITS_TOTAL:,.2f} USD, valid to {CREDITS_END} "
                 f"({days_left(today)} days left)")
    lines.append("")
    lines.append("Instances stopped, by region:")
    any_action = False
    for s in sweeps:
        if s["instances_stopped"] or s["spot_requests_cancelled"] or s["errors"]:
            any_action = True
            lines.append(f"  {s['region']}:")
            if s["instances_stopped"]:
                lines.append("    stopped: " + ", ".join(s["instances_stopped"]))
            if s["instances_ignored"]:
                lines.append(
                    "    left alone (SpendGuard=ignore): "
                    + ", ".join(s["instances_ignored"])
                )
            if s["spot_requests_cancelled"]:
                lines.append(
                    "    spot requests cancelled: "
                    + ", ".join(s["spot_requests_cancelled"])
                )
            for e in s["errors"]:
                lines.append(f"    ERROR: {e}")
    if not any_action:
        lines.append("  (nothing was running)")
    lines.append("")
    if lock["already_attached"]:
        lines.append(f"IAM group {GUEST_GROUP}: already locked with DenyAllForGuests.")
    elif lock["attached"]:
        lines.append(f"IAM group {GUEST_GROUP}: locked with DenyAllForGuests.")
    else:
        lines.append(
            f"IAM group {GUEST_GROUP}: NOT locked - {lock.get('error')}"
        )
    lines.append("")
    lines.append("To unlock the guest group again, run:")
    lines.append("")
    lines.append(f"  {UNLOCK_CMD}")
    lines.append("")
    lines.append(
        "Raise the thresholds with:\n"
        f"  aws lambda update-function-configuration --function-name {FUNCTION_NAME} \\\n"
        "    --environment 'Variables={WARN=4500,STOP=4800}'"
    )
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Handler
# --------------------------------------------------------------------------


def lambda_handler(event, context):
    event = event or {}
    dry_run = bool(event.get("dry_run", False))
    warn = float(event.get("WARN", DEFAULT_WARN))
    stop = float(event.get("STOP", DEFAULT_STOP))

    today = dt.datetime.now(dt.timezone.utc).date()
    now_iso = dt.datetime.now(dt.timezone.utc).isoformat()

    gross, month, monthly = get_gross_spend(today)
    log(
        f"gross_spend_since_{CREDITS_START}={gross} this_month={month} "
        f"warn={warn} stop={stop} dry_run={dry_run}"
    )

    state = load_state()
    report = {
        "checked_at": now_iso,
        "dry_run": dry_run,
        "gross_spend": gross,
        "this_month_spend": month,
        "monthly_breakdown": monthly,
        "warn_threshold": warn,
        "stop_threshold": stop,
        "credits_total": CREDITS_TOTAL,
        "credits_end": CREDITS_END,
        "days_until_credits_expire": days_left(today),
        "action": "none",
        "email_sent": False,
        "state_before": dict(state),
    }

    # ---------------- hard stop ----------------
    if gross >= stop:
        first_trip = not state.get("tripped_at")
        report["action"] = "hard_stop" if first_trip else "hard_stop_resweep"

        regions = enabled_regions()
        report["regions_checked"] = regions
        sweeps = [sweep_region(r, dry_run) for r in regions]
        report["sweeps"] = [s for s in sweeps if s["instances_stopped"]
                            or s["instances_ignored"]
                            or s["spot_requests_cancelled"]
                            or s["errors"]]
        report["instances_stopped"] = {
            s["region"]: s["instances_stopped"] for s in sweeps if s["instances_stopped"]
        }
        report["spot_requests_cancelled"] = {
            s["region"]: s["spot_requests_cancelled"]
            for s in sweeps
            if s["spot_requests_cancelled"]
        }

        lock = lock_guest_group(dry_run)
        report["guest_group_lock"] = lock

        did_something = bool(report["instances_stopped"]) or bool(
            report["spot_requests_cancelled"]
        )
        if first_trip or did_something:
            subject = (
                f"[AWS HARD STOP] {ACCOUNT_ID} gross spend {gross:,.0f} USD"
                if first_trip
                else f"[AWS HARD STOP active] {ACCOUNT_ID} re-stopped resources"
            )
            report["email_sent"] = publish(
                subject,
                stop_body(gross, month, today, stop, sweeps, lock, first_trip),
                dry_run,
            )

        if not dry_run:
            if first_trip:
                state["tripped_at"] = now_iso
            state["last_checked_at"] = now_iso
            state["last_gross"] = gross
            save_state(state)

    # ---------------- warning ----------------
    elif gross >= warn:
        band = int((gross - warn) // WARN_BAND)
        report["action"] = "warn"
        report["warn_band"] = band
        if state.get("last_warned_band") == band:
            report["action"] = "warn_suppressed_same_band"
        else:
            report["email_sent"] = publish(
                f"[AWS spend warning] {ACCOUNT_ID} gross spend {gross:,.0f} USD",
                warn_body(gross, month, today, warn, stop),
                dry_run,
            )
            if not dry_run:
                state["last_warned_at"] = now_iso
                state["last_warned_band"] = band
        if not dry_run:
            state["last_checked_at"] = now_iso
            state["last_gross"] = gross
            save_state(state)

    # ---------------- under both thresholds ----------------
    else:
        if not dry_run:
            state["last_checked_at"] = now_iso
            state["last_gross"] = gross
            save_state(state)

    report["state_after"] = state
    log(json.dumps(report, default=str))
    return report
