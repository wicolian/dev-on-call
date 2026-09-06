"""
gpu-swap
========

Turns one specific instance (INSTANCE_ID — see config.example.json) into a
`g4dn.xlarge` on-demand instance the moment the account is allowed to run one.

The account starts with the "Running On-Demand G and VT instances" quota
(L-DB2E81BA) at 0 vCPU, so a g4dn.xlarge (4 vCPU) cannot launch. A support case
raises it. This function polls the quota every 30 minutes and does the swap by
itself as soon as the quota reaches 4 vCPU, so nobody has to sit and watch the
support ticket.

Run order, every 30 minutes:

  1. GetServiceQuota L-DB2E81BA. Value < 4  -> log and exit.
     GetServiceQuota L-3819A6DF (spot G) is read and logged only. The swap is
     deliberately on-demand: a spot g4dn can be reclaimed mid-session, which is
     useless for a music workstation.
  2. DescribeInstances. Already g4dn.xlarge -> exit, publish nothing. The whole
     function is idempotent, so a stray extra invocation costs nothing.
  3. State is neither `running` nor `stopped` (pending / stopping / shutting
     down) -> exit and retry on the next run. Never modify a moving instance.
  4. `running` -> StopInstances, then the `instance_stopped` waiter for up to
     5 minutes. Still not stopped -> exit and retry next run.
  5. `stopped` -> ModifyInstanceAttribute InstanceType=g4dn.xlarge,
     StartInstances, record `swapped_at` in SSM, and email the owner.

Capacity failures are expected: the target region can run out of stock for the
target type. If StartInstances raises InsufficientInstanceCapacity the type is
reverted to FALLBACK_TYPE and the box is started again, so the owner is never
left with a dead machine. A retry counter lives in the SSM state; after
MAX_CAPACITY_RETRIES failed capacity retries the function gives up, emails
once, and stops trying.

State lives in the SSM parameter named by STATE_PARAM:

    {"swapped_at": "...", "capacity_retries": 0, "gave_up_at": "...",
     "last_checked_at": "...", "last_quota": 4.0}

Event options (all optional):
    {"dry_run": true}        - read everything, decide, change nothing.
                               No stop / modify / start / publish / state write.
    {"force": true}          - ignore a recorded swapped_at / gave_up_at and
                               evaluate again.
    {"REQUIRED_VCPUS": 4}    - override the quota bar for this invocation.
"""

import datetime as dt
import json
import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, WaiterError

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

ACCOUNT_ID = os.environ.get("ACCOUNT_ID", "123456789012")
HOME_REGION = os.environ.get("HOME_REGION", "us-east-1")

# No safe placeholder instance id — leave unset (empty) so this never
# accidentally targets a real box. Deploys must set INSTANCE_ID explicitly.
INSTANCE_ID = os.environ.get("INSTANCE_ID", "")
INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "gpu-workstation")

TARGET_TYPE = os.environ.get("TARGET_TYPE", "g4dn.xlarge")
FALLBACK_TYPE = os.environ.get("FALLBACK_TYPE", "m6i.xlarge")

# g4dn.xlarge is 4 vCPU, so the on-demand G quota must be at least 4.
ONDEMAND_G_QUOTA = os.environ.get("ONDEMAND_G_QUOTA", "L-DB2E81BA")
SPOT_G_QUOTA = os.environ.get("SPOT_G_QUOTA", "L-3819A6DF")
DEFAULT_REQUIRED_VCPUS = float(os.environ.get("REQUIRED_VCPUS", "4"))

# How long to wait for the box to reach `stopped` inside one invocation.
STOP_WAIT_DELAY = int(os.environ.get("STOP_WAIT_DELAY", "15"))
STOP_WAIT_ATTEMPTS = int(os.environ.get("STOP_WAIT_ATTEMPTS", "20"))  # 300 s

# Give up after this many InsufficientInstanceCapacity failures.
MAX_CAPACITY_RETRIES = int(os.environ.get("MAX_CAPACITY_RETRIES", "12"))

# Name this function is deployed as — only used for log/email text.
FUNCTION_NAME = os.environ.get("FUNCTION_NAME", "gpu-swap")

TOPIC_NAME = os.environ.get("TOPIC_NAME", "spend-guard-alerts")
TOPIC_ARN = os.environ.get(
    "TOPIC_ARN", f"arn:aws:sns:{HOME_REGION}:{ACCOUNT_ID}:{TOPIC_NAME}"
)
STATE_PARAM = os.environ.get("STATE_PARAM", "/aws-guards/gpu-swap/state")

CAPACITY_ERRORS = (
    "InsufficientInstanceCapacity",
    "InsufficientHostCapacity",
    "Unsupported",
)

BOTO_CFG = Config(
    retries={"max_attempts": 5, "mode": "standard"},
    connect_timeout=10,
    read_timeout=60,
)

ec2 = boto3.client("ec2", region_name=HOME_REGION, config=BOTO_CFG)
sq = boto3.client("service-quotas", region_name=HOME_REGION, config=BOTO_CFG)
ssm = boto3.client("ssm", region_name=HOME_REGION, config=BOTO_CFG)
sns = boto3.client("sns", region_name=HOME_REGION, config=BOTO_CFG)


def log(msg):
    print(msg, flush=True)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


# --------------------------------------------------------------------------
# Quotas
# --------------------------------------------------------------------------


def quota_value(quota_code):
    """Applied value for an ec2 quota, or None if it cannot be read."""
    try:
        return float(
            sq.get_service_quota(ServiceCode="ec2", QuotaCode=quota_code)["Quota"][
                "Value"
            ]
        )
    except ClientError as exc:
        log(f"WARN could not read quota {quota_code}: {exc}")
        return None


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


def save_state(state, dry_run):
    if dry_run:
        log(f"DRY RUN would save state: {json.dumps(state)}")
        return
    ssm.put_parameter(
        Name=STATE_PARAM,
        Value=json.dumps(state),
        Type="String",
        Overwrite=True,
        Description=f"{FUNCTION_NAME} state: swapped_at / capacity_retries",
    )


# --------------------------------------------------------------------------
# EC2
# --------------------------------------------------------------------------


def describe():
    """Return (instance_type, state_name) or (None, None) if it is gone."""
    try:
        reservations = ec2.describe_instances(InstanceIds=[INSTANCE_ID])[
            "Reservations"
        ]
    except ClientError as exc:
        log(f"ERROR describe_instances {INSTANCE_ID}: {exc}")
        return None, None
    for res in reservations:
        for inst in res.get("Instances", []):
            return inst["InstanceType"], inst["State"]["Name"]
    return None, None


def wait_for_stopped():
    """True if the instance reached `stopped` inside the wait budget."""
    waiter = ec2.get_waiter("instance_stopped")
    try:
        waiter.wait(
            InstanceIds=[INSTANCE_ID],
            WaiterConfig={"Delay": STOP_WAIT_DELAY, "MaxAttempts": STOP_WAIT_ATTEMPTS},
        )
        return True
    except WaiterError as exc:
        log(f"waiter did not see stopped in time: {exc}")
        return False


def set_type(instance_type):
    ec2.modify_instance_attribute(
        InstanceId=INSTANCE_ID, InstanceType={"Value": instance_type}
    )


# --------------------------------------------------------------------------
# Email
# --------------------------------------------------------------------------


def publish(subject, body, dry_run):
    if dry_run:
        log(f"DRY RUN would publish SNS: {subject}\n{body}")
        return False
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=body)
    return True


SUCCESS_BODY = (
    "{name} is now {target} with a T4 GPU. The NVIDIA driver installs itself on "
    "first boot; Parsec runs at 60 fps after one reboot."
)


def success_body():
    return SUCCESS_BODY.format(name=INSTANCE_NAME, target=TARGET_TYPE)


def capacity_body(retries, started_back, error):
    lines = [
        f"{INSTANCE_NAME} ({INSTANCE_ID}) could not become {TARGET_TYPE}: "
        f"{HOME_REGION} has no {TARGET_TYPE} capacity right now.",
        "",
        f"AWS said: {error}",
        "",
    ]
    if started_back:
        lines.append(
            f"The instance was put back to {FALLBACK_TYPE} and started again, so "
            "the box is usable as before. Nothing is lost."
        )
    else:
        lines.append(
            f"WARNING: the revert to {FALLBACK_TYPE} did not complete. Check the "
            f"instance and start it by hand:\n"
            f"  aws ec2 start-instances --instance-ids {INSTANCE_ID} "
            f"--region {HOME_REGION}"
        )
    lines.append("")
    lines.append(
        f"Capacity retry {retries} of {MAX_CAPACITY_RETRIES}. The swap is tried "
        "again on the next run, in 30 minutes."
    )
    return "\n".join(lines)


def gave_up_body(retries, error):
    return "\n".join(
        [
            f"{FUNCTION_NAME} has given up after {retries} capacity failures.",
            "",
            f"{HOME_REGION} has had no on-demand {TARGET_TYPE} capacity for the "
            f"last {retries} tries (about {retries // 2} hours). "
            f"{INSTANCE_NAME} stays on {FALLBACK_TYPE}.",
            "",
            f"Last error: {error}",
            "",
            "This is the only email about it. To try again, clear the state and "
            "the schedule picks it up within 30 minutes:",
            "",
            f"  aws ssm put-parameter --name {STATE_PARAM} --type String "
            f"--overwrite --value '{{}}' --region {HOME_REGION}",
            "",
            "Or ask for capacity in another availability zone, or use a "
            "g5.xlarge / g6.xlarge instead (same quota, different stock).",
        ]
    )


# --------------------------------------------------------------------------
# Handler
# --------------------------------------------------------------------------


def lambda_handler(event, context):
    event = event or {}
    dry_run = bool(event.get("dry_run", False))
    force = bool(event.get("force", False))
    required = float(event.get("REQUIRED_VCPUS", DEFAULT_REQUIRED_VCPUS))

    if not INSTANCE_ID:
        report = {
            "checked_at": now_iso(),
            "dry_run": dry_run,
            "decision": "not_configured",
            "reason": "INSTANCE_ID is not set — see config.example.json",
        }
        log(json.dumps(report, default=str))
        return report

    state = load_state()
    report = {
        "checked_at": now_iso(),
        "dry_run": dry_run,
        "instance_id": INSTANCE_ID,
        "instance_name": INSTANCE_NAME,
        "target_type": TARGET_TYPE,
        "required_vcpus": required,
        "decision": "none",
        "email_sent": False,
        "state_before": dict(state),
    }

    # ---------------- already done / already given up ----------------
    if state.get("swapped_at") and not force:
        report["decision"] = "already_swapped"
        report["swapped_at"] = state["swapped_at"]
        log(json.dumps(report, default=str))
        return report

    if state.get("gave_up_at") and not force:
        report["decision"] = "gave_up_earlier"
        report["gave_up_at"] = state["gave_up_at"]
        log(json.dumps(report, default=str))
        return report

    # ---------------- quotas ----------------
    ondemand = quota_value(ONDEMAND_G_QUOTA)
    spot = quota_value(SPOT_G_QUOTA)
    report["ondemand_g_quota"] = ondemand
    report["spot_g_quota"] = spot
    log(
        f"quota {ONDEMAND_G_QUOTA} (on-demand G vCPU) = {ondemand}; "
        f"quota {SPOT_G_QUOTA} (spot G vCPU) = {spot} "
        "(spot is read for information only, the swap is on-demand on purpose)"
    )

    if ondemand is None:
        report["decision"] = "quota_unreadable"
        log(json.dumps(report, default=str))
        return report

    if ondemand < required:
        report["decision"] = "quota_too_low"
        report["reason"] = (
            f"on-demand G quota is {ondemand} vCPU, need {required} for "
            f"{TARGET_TYPE}. Waiting for the support case."
        )
        log(report["reason"])
        if not dry_run:
            state["last_checked_at"] = report["checked_at"]
            state["last_quota"] = ondemand
            save_state(state, dry_run)
        report["state_after"] = state
        log(json.dumps(report, default=str))
        return report

    # ---------------- instance ----------------
    itype, istate = describe()
    report["instance_type"] = itype
    report["instance_state"] = istate

    if itype is None:
        report["decision"] = "instance_not_found"
        log(json.dumps(report, default=str))
        return report

    if itype == TARGET_TYPE:
        # Idempotent: somebody (or an earlier run) already did it. No email.
        report["decision"] = "already_target_type"
        if not dry_run:
            state["swapped_at"] = state.get("swapped_at") or now_iso()
            state["last_checked_at"] = report["checked_at"]
            save_state(state, dry_run)
        report["state_after"] = state
        log(json.dumps(report, default=str))
        return report

    if istate not in ("running", "stopped"):
        report["decision"] = "transient_state_retry_next_run"
        report["reason"] = f"state is {istate}; not touching a moving instance"
        log(report["reason"])
        log(json.dumps(report, default=str))
        return report

    # ---------------- stop it if it is running ----------------
    if istate == "running":
        if dry_run:
            report["decision"] = "would_stop_then_swap"
            report["reason"] = (
                f"quota {ondemand} >= {required}; would stop {INSTANCE_ID}, "
                f"wait up to {STOP_WAIT_DELAY * STOP_WAIT_ATTEMPTS}s for "
                f"stopped, set type {TARGET_TYPE}, start it, and email."
            )
            log(json.dumps(report, default=str))
            return report

        log(f"stopping {INSTANCE_ID} to change its type")
        try:
            ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        except ClientError as exc:
            report["decision"] = "stop_failed"
            report["error"] = str(exc)
            log(json.dumps(report, default=str))
            return report

        if not wait_for_stopped():
            report["decision"] = "still_stopping_retry_next_run"
            report["reason"] = (
                "did not reach stopped inside the wait budget; the next run "
                "picks it up from `stopped`"
            )
            state["last_stop_requested_at"] = now_iso()
            state["last_checked_at"] = report["checked_at"]
            save_state(state, dry_run)
            report["state_after"] = state
            log(json.dumps(report, default=str))
            return report
        report["stopped_by_this_run"] = True

    # ---------------- stopped: swap and start ----------------
    if dry_run:
        report["decision"] = "would_swap"
        report["reason"] = (
            f"quota {ondemand} >= {required} and instance is stopped; would set "
            f"type {TARGET_TYPE}, start it, and email."
        )
        log(json.dumps(report, default=str))
        return report

    try:
        set_type(TARGET_TYPE)
    except ClientError as exc:
        report["decision"] = "modify_failed"
        report["error"] = str(exc)
        log(json.dumps(report, default=str))
        return report
    log(f"instance type set to {TARGET_TYPE}")

    try:
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in CAPACITY_ERRORS:
            report["decision"] = "start_failed"
            report["error"] = str(exc)
            log(json.dumps(report, default=str))
            return report

        # ---- no g4dn stock: put the box back the way it was ----
        retries = int(state.get("capacity_retries", 0)) + 1
        report["decision"] = "insufficient_capacity"
        report["capacity_retries"] = retries
        report["error"] = str(exc)
        log(f"no {TARGET_TYPE} capacity (try {retries}); reverting to {FALLBACK_TYPE}")

        started_back = False
        revert_error = None
        try:
            set_type(FALLBACK_TYPE)
            ec2.start_instances(InstanceIds=[INSTANCE_ID])
            started_back = True
        except ClientError as revert_exc:
            revert_error = str(revert_exc)
            log(f"ERROR could not revert to {FALLBACK_TYPE}: {revert_exc}")
        report["reverted_and_started"] = started_back
        report["revert_error"] = revert_error

        state["capacity_retries"] = retries
        state["last_capacity_error"] = str(exc)
        state["last_checked_at"] = report["checked_at"]

        if retries >= MAX_CAPACITY_RETRIES:
            state["gave_up_at"] = now_iso()
            report["decision"] = "gave_up_no_capacity"
            report["email_sent"] = publish(
                f"[{FUNCTION_NAME}] giving up: no {TARGET_TYPE} capacity in "
                f"{HOME_REGION}",
                gave_up_body(retries, str(exc)),
                dry_run,
            )
        else:
            report["email_sent"] = publish(
                f"[{FUNCTION_NAME}] no {TARGET_TYPE} capacity, retry "
                f"{retries}/{MAX_CAPACITY_RETRIES}",
                capacity_body(retries, started_back, str(exc)),
                dry_run,
            )

        save_state(state, dry_run)
        report["state_after"] = state
        log(json.dumps(report, default=str))
        return report

    # ---------------- success ----------------
    report["decision"] = "swapped"
    state["swapped_at"] = now_iso()
    state["capacity_retries"] = 0
    state["last_checked_at"] = report["checked_at"]
    state["last_quota"] = ondemand
    state.pop("last_capacity_error", None)
    save_state(state, dry_run)

    report["email_sent"] = publish(
        f"[{FUNCTION_NAME}] {INSTANCE_NAME} is now {TARGET_TYPE}",
        success_body(),
        dry_run,
    )
    report["state_after"] = state
    log(json.dumps(report, default=str))
    return report
