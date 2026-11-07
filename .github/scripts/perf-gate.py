#!/usr/bin/env python3
"""Compare the CI benchmark's medians with .github/perf-budget.json.

Usage: perf-gate.py <metrics.json> <perf-budget.json>

<metrics.json> is `xcrun xcresulttool get test-results metrics --path X.xcresult`.
Every metric of every test is printed as a table (and appended to
$GITHUB_STEP_SUMMARY when set). A budget entry fails the gate when its
metric's median is above `max`, and also when the metric is missing from the
results: a benchmark that silently stopped measuring must not pass.
Metrics without a budget entry are reported only.
"""

import json
import os
import statistics
import sys


def collect(node, test=None, out=None):
    """Walk the JSON and yield (test, metric name, unit, measurements).

    The walker does not hard-code xcresulttool's schema beyond the field
    names: a dict with `testIdentifier` names the test for everything under
    it, a dict with a `measurements` list is one metric.
    """
    if out is None:
        out = []
    if isinstance(node, dict):
        test = node.get("testIdentifier", test)
        measurements = node.get("measurements")
        if isinstance(measurements, list) and measurements:
            name = node.get("displayName") or node.get("identifier") or "?"
            unit = node.get("unitOfMeasurement") or node.get("unit") or ""
            values = [float(v) for v in measurements if isinstance(v, (int, float))]
            if values:
                out.append((test or "?", name, unit, values))
        for value in node.values():
            collect(value, test, out)
    elif isinstance(node, list):
        for value in node:
            collect(value, test, out)
    return out


def matches(entry, test, name):
    return entry["test"] in test and entry["metric"] in name


def main():
    metrics_path, budget_path = sys.argv[1], sys.argv[2]
    with open(metrics_path, encoding="utf-8") as f:
        results = collect(json.load(f))
    with open(budget_path, encoding="utf-8") as f:
        budget = json.load(f)["budgets"]

    rows = []
    failures = []
    for test, name, unit, values in results:
        median = statistics.median(values)
        entry = next((b for b in budget if matches(b, test, name)), None)
        if entry is None:
            status, limit = "report", ""
        elif median > entry["max"]:
            status, limit = "OVER", f"{entry['max']:g}"
            failures.append(f"{test} / {name}: median {median:.3f} {unit} > budget {entry['max']:g}")
        else:
            status, limit = "ok", f"{entry['max']:g}"
        spread = ", ".join(f"{v:.3f}" for v in values)
        rows.append(f"| {test} | {name} | {median:.3f} {unit} | {limit} | {status} | {spread} |")

    for entry in budget:
        if not any(matches(entry, test, name) for test, name, _, _ in results):
            failures.append(f"{entry['test']} / {entry['metric']}: no measurements in the result bundle")

    table = "\n".join([
        "| Test | Metric | Median | Budget | Status | Runs |",
        "|---|---|---|---|---|---|",
        *rows,
    ])
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## Benchmark\n\n" + table + "\n")

    if not results:
        print("::error::The result bundle has no performance metrics")
        return 1
    for failure in failures:
        print(f"::error::{failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
