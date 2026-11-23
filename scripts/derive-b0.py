#!/usr/bin/env python3
"""Derive B0 parameters from ordered runs; print JSON, never alter input data.

Usage: python3 scripts/derive-b0.py runs/b0-one runs/b0-continued
The inputs must cover strictly increasing target_rps and include an error stage.
"""

import argparse
import csv
import json
from decimal import Decimal, InvalidOperation, ROUND_FLOOR, localcontext
from pathlib import Path


COUNTERS = ("sent", "ok", "http_err", "timeout", "net_err", "dropped")
METRICS = ("p99_ms", "lag_p99_ms", "gen_cpu_pct")
REQUIRED = {"step", "target_rps", "start_unix", "end_unix", *COUNTERS, *METRICS}


def decimal_value(value, label):
    try:
        result = Decimal(value)
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ValueError(f"{label}: expected a decimal, got {value!r}") from exc
    if not result.is_finite():
        raise ValueError(f"{label}: expected a finite decimal")
    return result


def plain(value):
    text = format(value, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def read_stages(run_dirs):
    stages = []
    last_target = None
    for run_dir in run_dirs:
        path = Path(run_dir) / "steps.csv"
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            missing = REQUIRED - set(reader.fieldnames or ())
            if missing:
                raise ValueError(f"{path}: missing columns: {', '.join(sorted(missing))}")
            run_stages = 0
            for line, row in enumerate(reader, start=2):
                step = (row["step"] or "").strip()
                if step.lower() == "all":
                    continue
                label = f"{path}:{line} (step {step})"
                if not step:
                    raise ValueError(f"{label}: empty step")
                target = decimal_value(row["target_rps"], label)
                if target <= 0 or (last_target is not None and target <= last_target):
                    raise ValueError(f"{label}: target_rps must be positive and strictly increasing across inputs")
                last_target = target
                start = decimal_value(row["start_unix"], label)
                end = decimal_value(row["end_unix"], label)
                duration = end - start
                if duration <= 0:
                    raise ValueError(f"{label}: end_unix must exceed start_unix")
                counts = {}
                for field in COUNTERS:
                    try:
                        counts[field] = int(row[field])
                    except (TypeError, ValueError) as exc:
                        raise ValueError(f"{label}: {field} must be an integer") from exc
                    if counts[field] < 0:
                        raise ValueError(f"{label}: {field} must not be negative")
                errors = counts["http_err"] + counts["timeout"] + counts["net_err"]
                if counts["sent"] <= 0 or counts["sent"] != counts["ok"] + errors:
                    raise ValueError(f"{label}: expected positive sent == ok + http_err + timeout + net_err")
                stage = {
                    "run": str(run_dir), "steps_csv": str(path), "step": step,
                    "target_rps": plain(target), "start_unix": plain(start),
                    "end_unix": plain(end), "duration_seconds": plain(duration),
                    "counts": counts, "error_count": errors,
                    "ok_rps_from_counts": plain(Decimal(counts["ok"]) / duration),
                }
                for field in METRICS:
                    value = (row[field] or "").strip()
                    stage[field] = plain(decimal_value(value, f"{label}: {field}")) if value else None
                stages.append(stage)
                run_stages += 1
            if not run_stages:
                raise ValueError(f"{path}: no individual stages")
    return stages


def derive(run_dirs):
    with localcontext() as context:
        context.prec = 50
        stages = read_stages(run_dirs)
        first_error_index = next((i for i, stage in enumerate(stages) if stage["error_count"] > 0), None)
        if first_error_index is None:
            raise ValueError("No stage has an HTTP, timeout, or network error: the upper limit is not established; continue probing at higher rates in a new run directory.")
        prefix = stages[:first_error_index]
        if not prefix:
            raise ValueError("The first stage already has errors: probe lower rates to obtain an error-free prefix.")
        for stage in prefix:
            if stage["counts"]["dropped"] != 0:
                raise ValueError(f"{stage['steps_csv']} step {stage['step']}: dropped requests invalidate the pre-error prefix; inspect the generator and repeat.")
        selected = max(prefix, key=lambda stage: Decimal(stage["ok_rps_from_counts"]))
        upper = Decimal(selected["counts"]["ok"]) / Decimal(selected["duration_seconds"])
        capacity = Decimal("0.7") * upper
        peak = (Decimal(4) * capacity / Decimal(10)).to_integral_value(rounding=ROUND_FLOOR) * Decimal(10)
        base = peak / Decimal(10)
        constant_cd = Decimal(2) * capacity
        if not (peak > Decimal(2) * upper and Decimal(3) * capacity < peak <= Decimal(4) * capacity):
            raise ValueError("Derived P fails required constraints P > 2U and 3C < P <= 4C; inspect the measurements and rounding before handoff.")
        base_text, peak_text = plain(base), plain(peak)
        return {
            "inputs": list(run_dirs),
            "selection_rule": "Maximum ok/(end_unix-start_unix) among stages preceding the first http_err+timeout+net_err > 0; every preceding stage must have dropped=0.",
            "rounding_rule": "C=0.7*U without preliminary rounding; P=10*floor(4*C/10); BASE=P/10; CD=2*C. This is the group's explicit rounding convention.",
            "selected": selected,
            "first_error": stages[first_error_index],
            "U": plain(upper), "C": plain(capacity), "P": peak_text,
            "BASE": base_text, "CD": plain(constant_cd),
            "PLAN": f"{base_text}@120s,{base_text}~{peak_text}@30s,{peak_text}@300s,{peak_text}~{base_text}@60s,{base_text}@120s",
            "plan_duration_seconds": 630,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dirs", nargs="+", help="Run directories in strictly increasing target_rps order")
    args = parser.parse_args()
    try:
        result = derive(args.run_dirs)
    except (OSError, ValueError) as exc:
        parser.exit(2, f"derive-b0: {exc}\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
