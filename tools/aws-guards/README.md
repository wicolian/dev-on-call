# aws-guards

Three small, dependency-free Lambda functions for keeping a shared AWS
account's EC2 spend under control: a hard spending stop, an idle-instance
stopper, and a one-instance GPU quota swapper. Ported from a private
account-ops repo into this public one, so every account id, instance id,
ARN, and IAM group/policy name that used to be hard-coded is now either a
placeholder default or an environment variable — see
[`config.example.json`](config.example.json) for the full list per
function. **None of the values in this directory are real.**

This is a standalone toolkit, not wired into the Dev On Call app itself —
it complements the app's read-only "AWS Boxes" popover with the
account-side enforcement that actually stops runaway spend even when
nobody has the popover open.

| Function | File | Schedule (suggested) | What it does |
|---|---|---|---|
| `spend-guard` | `lambda_function.py` | daily | Warns at a gross-spend threshold, hard-stops everything (every running instance, every persistent spot request, locks a guest IAM group) at a higher one. |
| `gpu-swap` | `gpu-swap/lambda_function.py` | every 30 min | Swaps one named instance to a GPU instance type the moment an on-demand quota allows it, reverting on capacity failure. |
| `idle-stop` | `idle-stop/lambda_function.py` | hourly | Stops any EC2 instance idle (low CPU, low inbound packets) for a configurable window, in every enabled region. |

All three are plain Python 3.12, `boto3` only (already in the Lambda
runtime — no deployment package needed beyond the single file), and all
three accept `{"dry_run": true}` to read and decide without changing
anything.

## Thresholds

| Function | Env var | Default | Meaning |
|---|---|---|---|
| spend-guard | `WARN` | `3500` | Gross USD spend that triggers one warning email. |
| spend-guard | `STOP` | `4000` | Gross USD spend that triggers the hard stop. |
| spend-guard | `WARN_BAND` | `100` | Re-warn once per this many dollars above `WARN`. |
| gpu-swap | `REQUIRED_VCPUS` | `4` | On-demand GPU-family quota needed before swapping. |
| gpu-swap | `MAX_CAPACITY_RETRIES` | `12` | Give up after this many `InsufficientInstanceCapacity` failures. |
| idle-stop | `IDLE_HOURS` | `3` | Window checked for idleness. |
| idle-stop | `CPU_AVG_MAX` / `CPU_PEAK_MAX` | `3` / `15` | Average / peak CPU% bars, both must be under. |
| idle-stop | `PACKETS_MAX` | `3000` | Per-5-minute inbound-packet bar (the one that avoids false positives from SSH keepalives). |

Every threshold is an environment variable, so tuning one is a
`update-function-configuration` call — no redeploy. The same keys also
work as one-off event payload overrides (e.g.
`{"dry_run": true, "WARN": 100}`) for testing a new number safely first.

## Deploying

Each function is a single file with no third-party dependencies, so the
"build" is just zipping that one file:

```sh
# spend-guard
zip -j fn.zip tools/aws-guards/lambda_function.py
aws lambda update-function-code --function-name <your-spend-guard-name> \
  --region <your-region> --zip-file fileb://fn.zip

# gpu-swap
(cd tools/aws-guards/gpu-swap && zip -j ../../../fn.zip lambda_function.py)
aws lambda update-function-code --function-name <your-gpu-swap-name> \
  --region <your-region> --zip-file fileb://fn.zip

# idle-stop
(cd tools/aws-guards/idle-stop && zip -j ../../../fn.zip lambda_function.py)
aws lambda update-function-code --function-name <your-idle-stop-name> \
  --region <your-region> --zip-file fileb://fn.zip
```

To create a function for the first time, see the IAM templates below, then
`aws lambda create-function --runtime python3.12 --handler
lambda_function.lambda_handler --role <role-arn> --zip-file
fileb://fn.zip --function-name <name>`, and an EventBridge schedule rule
(`aws events put-rule --schedule-expression 'rate(1 hour)'` /
`cron(...)`) targeting it.

## Configuration

Nothing in these functions is hard-coded to a real account. Every
identifier is read from an environment variable with either a generic
default (`123456789012`, `us-east-1`, `spend-guard-alerts`, …) or, where
no safe generic default exists (a specific instance id), an empty
default that makes the function a safe no-op until configured.

Copy the values you need from [`config.example.json`](config.example.json)
into your function's environment, e.g.:

```sh
aws lambda update-function-configuration \
  --function-name <your-spend-guard-name> --region <your-region> \
  --environment 'Variables={ACCOUNT_ID=<acct>,HOME_REGION=<region>,WARN=3500,STOP=4000,TOPIC_ARN=arn:aws:sns:<region>:<acct>:<topic>,GUEST_GROUP=<group>,DENY_POLICY_ARN=arn:aws:iam::<acct>:policy/DenyAllForGuests,STATE_PARAM=/aws-guards/spend-guard/state}'
```

`--environment` **replaces** the whole variable map, so pass every
variable you want to keep, every time.

## IAM

`policies/`, `gpu-swap/policies/`, and `idle-stop/policies/` hold the
trust policy (`trust.json`, identical for all three: only
`lambda.amazonaws.com` may assume the role) and each function's least-
privilege inline role policy (`role-inline.json`). `policies/` also has
`DenyAllForGuests.json` (the lock policy spend-guard attaches to the
guest group) and `selfservice-v2.json` (an example self-service policy
for letting IAM users manage their own access keys/MFA — not required by
any of the three functions, kept for reference).

**These are hand-edit templates, not runtime config.** Every
`<ACCOUNT_ID>`, `<REGION>`, `<GUEST_GROUP>`, `<TOPIC_NAME>`,
`<STATE_PATH_PREFIX>`, and `<INSTANCE_ID>` placeholder must be replaced
with your real values before creating the policy/role — `sed` them, or
edit by hand. `config.example.json`'s `iam_policy_placeholders` section
lists what each token means.

`gpu-swap`'s role scopes `StopInstances` / `StartInstances` /
`ModifyInstanceAttribute` to exactly one instance ARN — it cannot touch
any other box in the account, however it's configured.

## Testing safely

All three read `{"dry_run": true}` and, with it, do everything except the
actual mutation (stop/start/modify/attach) and the SNS publish:

```sh
aws lambda invoke --function-name <name> --region <region> \
  --cli-binary-format raw-in-base64-out --payload '{"dry_run": true}' /dev/stdout
```

`spend-guard` also takes `{"STOP": 0}` to exercise the hard-stop branch
read-only; `gpu-swap` takes `{"REQUIRED_VCPUS": 0}` to exercise the swap
branch read-only; `idle-stop` takes a shortened `{"IDLE_HOURS": 0.5,
"MIN_DATAPOINTS": 3}` to check the metrics path on a box that hasn't been
up for the full window yet.

## Notes

- Nothing here is terminated, ever — only stopped. `spend-guard` and
  `idle-stop` both call `StopInstances`, never `TerminateInstances`.
- `idle-stop`'s packet-count bar is what keeps SSH keepalives and
  background VPN chatter from reading as "busy" — see the docstring at
  the top of `idle-stop/lambda_function.py` for the reasoning.
- State (spend-guard's warn/trip record, gpu-swap's swap/retry record)
  lives in SSM Parameter Store, one parameter per function, path
  configurable via `STATE_PARAM`.
