#!/usr/bin/env python3
"""Print p50/p95 for a file of timings and exit non-zero when p95 is over budget.

    latency.py <timings-file> <budget-seconds>

Exiting non-zero is the point: a latency check that only prints cannot fail the
suite, which means it cannot veto anything.
"""
import math
import statistics
import sys

values = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
budget = float(sys.argv[2])
if not values:
    print("  no timings recorded")
    sys.exit(1)

p50 = statistics.median(values)
# Nearest rank, ceil not round. The caller drops fail-open invocations, so n is
# not fixed at 20: with 19 values round(18.05) selects rank 18, and an
# over-budget value at rank 19 would slip past the veto.
idx = max(0, min(len(values) - 1, math.ceil(0.95 * len(values)) - 1))
p95 = values[idx]
print(f"  n={len(values)}  p50 {p50:.3f}s  p95 {p95:.3f}s  "
      f"min {values[0]:.3f}s  max {values[-1]:.3f}s  budget {budget:.1f}s")
sys.exit(0 if p95 <= budget else 1)
