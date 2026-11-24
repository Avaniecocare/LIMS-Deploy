#!/usr/bin/env python3
"""Writes every query of dashboard.json as a rule file, for promtool to check, and fails on a metric the app does not have.

  monitoring/dashboard-check.py <LIMS checkout> > rules.yaml && promtool check rules rules.yaml
"""
import json, pathlib, re, sys

here = pathlib.Path(__file__).parent
source = "\n".join(p.read_text() for p in pathlib.Path(sys.argv[1], "src").rglob("*.ts"))
known = set(re.findall(r"'(lims_[a-z_]+)'", source))
exprs = [t["expr"].replace("$namespace", ".*") for p in json.loads((here / "dashboard.json").read_text())["panels"] for t in p["targets"]]
used = {re.sub(r"_(bucket|count|sum)$", "", m) for e in exprs for m in re.findall(r"lims_[a-z_]+", e)}
missing = sorted(used - known)
if missing:
    sys.exit(f"The app has no metric called {', '.join(missing)}")
print("groups:\n  - name: dashboard\n    rules:")
for n, e in enumerate(exprs):
    print(f"      - record: check:q{n}\n        expr: {json.dumps(e)}")
