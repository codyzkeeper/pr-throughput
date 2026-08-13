#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "usage: $0 OUTPUT.json"
  exit 64
fi

repo_root="${0:A:h:h}"
output="${1:A}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pr-throughput-canonical.XXXXXX")"
build_root="$work_dir/build"
product="$build_root/Build/Products/Debug/PRThroughputLiveE2E"
bounded="$repo_root/Scripts/run_with_timeout.py"
mkdir -p "${output:h}"
tmp="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -rf "$work_dir"; rm -f "$tmp"' EXIT

"$bounded" 1800 xcodebuild \
  -project "$repo_root/PRThroughput.xcodeproj" \
  -scheme PRThroughputLiveE2E \
  -configuration Debug \
  -derivedDataPath "$build_root" \
  build >/dev/null

"$bounded" 15 security find-generic-password \
  -w \
  -a oauth-token \
  -s app.prthroughput.PRThroughput.github \
  | "$bounded" 1800 "$product" --canonical-metrics >"$tmp"

/usr/bin/python3 - "$tmp" "${PR_THROUGHPUT_EXPECTED_LOGIN:-}" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
expected_login = sys.argv[2].strip().casefold()
data = json.loads(p.read_text())
required = {"schemaVersion", "metricContractVersion", "primaryRange", "asOf", "viewerLogin", "sourceDigest", "ranges"}
if not required.issubset(data) or data["schemaVersion"] != 4 or data["metricContractVersion"] != "4" or data["primaryRange"] != "7d":
    raise SystemExit("canonical metric snapshot failed contract validation")
if not isinstance(data.get("viewerLogin"), str) or not data["viewerLogin"].strip():
    raise SystemExit("canonical metric snapshot has no authenticated viewer")
if expected_login and data["viewerLogin"].casefold() != expected_login:
    raise SystemExit("canonical metric snapshot is authenticated as an unexpected account")
if {item.get("range") for item in data["ranges"]} != {"48h", "7d", "30d"}:
    raise SystemExit("canonical metric snapshot is missing a required range")
if len(data["ranges"]) != 3:
    raise SystemExit("canonical metric snapshot contains duplicate ranges")
for item in data["ranges"]:
    label = item["range"]
    metrics = item["metrics"]
    if item.get("windowStart") != metrics.get("windowStart") or metrics.get("asOf") != data["asOf"]:
        raise SystemExit(f"{label} window boundaries do not reconcile")
    expected_open = (metrics["openAtStart"] + metrics["new"] + metrics["reentered"]
                     - metrics["merged"] - metrics["closed"] - metrics["drafted"])
    if expected_open != metrics["openNow"]:
        raise SystemExit(f"{label} backlog ledger does not reconcile")
    if metrics["netChange"] != metrics["openNow"] - metrics["openAtStart"]:
        raise SystemExit(f"{label} net backlog change does not reconcile")
    if metrics["decisions"] != metrics["approved"] + metrics["changesRequested"]:
        raise SystemExit(f"{label} review totals do not reconcile")
    id_counts = (
        ("openAtStart", "openAtStartIDs"),
        ("new", "newIDs"),
        ("reentered", "reenteredTransitions"),
        ("merged", "mergedIDs"),
        ("closed", "closedTransitions"),
        ("drafted", "draftedTransitions"),
        ("openNow", "openAtEndIDs"),
        ("handoffs", "handoffIDs"),
        ("approved", "approvalEventIDs"),
        ("changesRequested", "changesRequestedEventIDs"),
        ("awaitingNow", "awaitingHandoffIDs"),
    )
    for count_name, facts_name in id_counts:
        facts = metrics.get(facts_name)
        if not isinstance(facts, list) or metrics[count_name] != len(facts):
            raise SystemExit(f"{label} {count_name} does not match its source facts")
        fact_ids = [fact.get("id") if isinstance(fact, dict) else fact for fact in facts]
        if len(fact_ids) != len(set(fact_ids)):
            raise SystemExit(f"{label} {facts_name} contains duplicate facts")
    expected_rates = (
        ("acceptanceRate", metrics["approved"], metrics["decisions"]),
        ("reworkRate", metrics["changesRequested"], metrics["decisions"]),
    )
    for name, numerator, denominator in expected_rates:
        expected = None if denominator == 0 else numerator / denominator
        actual = metrics.get(name)
        if (actual is None) != (expected is None) or (actual is not None and abs(actual - expected) > 1e-7):
            raise SystemExit(f"{label} {name} does not reconcile")
digest = data.get("sourceDigest", "")
if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
    raise SystemExit("canonical metric snapshot has an invalid source digest")
PY

mv "$tmp" "$output"
rm -rf "$work_dir"
trap 'rm -f "$tmp"' EXIT
print "$output"
