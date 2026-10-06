"""Write a short report from saved scores; never call a model."""
import json
import sys
from pathlib import Path

DEFINITIONS = {
    "printed-example": "Current production plus the fifth example, using printed_label/printed_amount/printed_rate. One item GST entry stays separate from footer CGST and SGST entries. No schema changes or kind classification.",
    "production": "The unmodified production request at the time of this run. Run 001 lacks footer rates; run 006 includes the adopted footer-rate field and updated examples.",
    "footer-rate": "Production plus nullable `printed_rate` on invoice-footer tax entries. Keeps literal tax labels and the existing prompt. No `kind` conversion.",
    "scoped-kind": "Footer-rate plus semantic tax objects: `printed_label`, `printed_amount`, `printed_rate` become `kind`, `amount`, `rate`. Allowed kinds: cgst, sgst, igst, cess, combined, unknown. Descriptions separately name the item or invoice summary. An added boundary rule forbids splitting, duplicating or borrowing entries across those regions. Examples use the new fields.",
    "observed-kind": "Scoped-kind with only `kind` renamed to `observed_kind` in the schema, instructions and examples. Same meanings and allowed values.",
    "mixed-example": "Scoped-kind plus one example: item GST 180 at 18% stays one combined entry; footer CGST 90 at 9% and SGST 90 at 9% stay two summary entries. Schema unchanged from scoped-kind.",
    "single-rule": "Scoped-kind with its generic tax instruction and appended boundary rule replaced by one instruction at the original location. Keeps the boundary rule and prohibition on using addresses to infer tax kind. Schema unchanged from scoped-kind; no extra mixed-tax example.",
    "reference": "The frozen footer-rate prompt and schema from earlier runs, loaded through inputs/settings.json. Compared with updated production without rebuilding the old control.",
}


def report(root):
    summary = json.loads((root / "summary.json").read_text(encoding="utf-8"))
    lines = [f"# {root.name}", "", "## What each version changes", "",
             "These names identify request variants, not different models.", "",
             "| Version | Change |", "|---|---|"]
    arms = list(summary)
    if any(arm in summary for arm in ("observed-kind", "mixed-example", "single-rule")):
        arms = [arm for arm in ("production", "footer-rate", "scoped-kind",
                               "observed-kind", "mixed-example", "single-rule", "reference")
                if arm in summary or arm == "scoped-kind"]
    for arm in arms:
        lines.append(f"| {arm} | {DEFINITIONS[arm]} |")
    if any(arm in summary for arm in ("scoped-kind", "mixed-example", "single-rule")):
        lines += ["", "**Important:** observed-kind, mixed-example and single-rule each start from",
                  "scoped-kind. They are separate changes; they do not build on each other.",
                  "Footer-rate is the simpler production-style control."]
    lines += ["", "## Results", "", "Final accounting and the application's review decision:", "",
             "| Version | Correct, ready | Wrong, held | Correct, held | Wrong, ready |",
             "|---|---:|---:|---:|---:|"]
    for arm, result in summary.items():
        counts = result["readiness"]
        cells = [str(counts.get(key, 0)) for key in
                 ("correct_ready", "wrong_held", "correct_held", "wrong_ready")]
        lines.append(f"| {arm} | " + " | ".join(cells) + " |")
    if root.name in ("002-kind-regression-gate", "003-kind-broader", "004-final-check"):
        replay = f"../005-rounding-fix-replay/{root.name}/summary.json"
        lines += ["", "These are the original results, before the separate GSTR-1 rounding fix.",
                  "The wrong-ready answers in runs 002 and 004 came from our code omitting",
                  "rounding from invoice values. They were not all model extraction errors.",
                  f"[Scores after replaying the rounding fix]({replay}) use the same model answers."]
    lines += ["", "A wrong raw observation can still lead to correct accounting. See the",
              "separate raw-fact checks in [summary.json](summary.json).", "",
              "Repeated answers are consistency checks, not independent invoice layouts.", "",
              "[Plan](PLAN.md) · [Every score](scores.json)"]
    if (root / "audit.json").exists():
        lines.append(" · [Request audit](audit.json)")
    findings = root / "FINDINGS.md"
    if findings.exists():
        lines += ["", findings.read_text(encoding="utf-8").strip()]
    prepared = root / "inputs" / "prepared"
    if prepared.exists():
        lines += ["", "## Read the actual contract", ""]
        case = next(iter(sorted(prepared.iterdir())))
        for arm in sorted(case.iterdir()):
            rel = arm.relative_to(root).as_posix()
            lines.append(f"- {arm.name}: [schema]({rel}/schema.json), [prompt]({rel}/prompt.txt)")
    (root / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    report(Path(sys.argv[1]))
