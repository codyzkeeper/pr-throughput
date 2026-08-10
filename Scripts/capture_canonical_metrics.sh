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
if not required.issubset(data) or data["schemaVersion"] != 3 or data["metricContractVersion"] != "3" or data["primaryRange"] != "7d":
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
    activity = item["activity"]
    metrics = item["metrics"]
    if activity["approved"] < 0 or activity["changesRequested"] < 0:
        raise SystemExit(f"{label} activity decision counts cannot be negative")
    if activity["awaiting"] > activity["handoffs"]:
        raise SystemExit(f"{label} awaiting handoffs exceed window handoffs")
    if metrics["opened"] != metrics["open"] + metrics["merged"] + metrics["closedUnmerged"]:
        raise SystemExit(f"{label} shipping totals do not reconcile")
    if metrics["decisions"] != metrics["approved"] + metrics["changesRequested"]:
        raise SystemExit(f"{label} review totals do not reconcile")
    if metrics["handedOff"] > metrics["opened"]:
        raise SystemExit(f"{label} handoffs exceed the opened cohort")
    expected_rates = (
        ("mergeCompletionRate", metrics["merged"], metrics["opened"]),
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
