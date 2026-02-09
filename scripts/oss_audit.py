#!/usr/bin/env python3
from __future__ import annotations
import subprocess
from pathlib import Path
import re
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[1]

PATTERNS = {
    "private_key": re.compile(r"-----BEGIN (?:RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----"),
    "github_token": re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    "api_key_assignment": re.compile(r"(?i)\bapi[_-]?key\b\s*[:=]\s*['\"][^'\"]{8,}"),
    "secret_assignment": re.compile(r"(?i)\bsecret\b\s*[:=]\s*['\"][^'\"]{6,}"),
    "token_assignment": re.compile(r"(?i)\b(access|auth|bearer)[ _-]?token\b\s*[:=]\s*['\"][^'\"]{6,}"),
    "password_assignment": re.compile(r"(?i)\bpassword\b\s*[:=]\s*['\"][^'\"]+"),
    "telemetry_vendor": re.compile(r"(?i)\b(telemetry|analytics|sentry|mixpanel|amplitude|firebase)\b"),
    "corp_reference": re.compile(r"(?i)\b(microsoft(?!\.github\.io)|internal only|corp|confidential|nda)\b"),
}

ALLOW_HINTS = (
    "example",
    "placeholder",
    "sample",
    "dummy",
    "docs",
    "test",
)


def git_files() -> list[str]:
    out = subprocess.check_output(["git", "-C", str(REPO), "ls-files"], text=True)
    return [line for line in out.splitlines() if line]


def is_binary(path: Path) -> bool:
    try:
        data = path.read_bytes()
    except Exception:
        return False
    return b"\x00" in data


def check_file(path: Path):
    if is_binary(path):
        return "binary", []

    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        try:
            text = path.read_text(encoding="latin-1")
        except Exception:
            return "unreadable", []

    findings = []
    lower = text.lower()
    for name, pattern in PATTERNS.items():
        for m in pattern.finditer(text):
            snippet = text[max(0, m.start()-80): m.end()+80].replace("\n", " ").strip()
            benign = any(h in lower for h in ALLOW_HINTS)
            findings.append((name, snippet[:180], benign))
            break
    return "text", findings


def main() -> int:
    files = git_files()
    rows = []
    flagged = []
    for f in files:
        p = REPO / f
        kind, findings = check_file(p)
        status = "PASS"
        notes = "No suspicious patterns"
        if kind == "binary":
            notes = "Binary asset (pattern scan skipped)"
        elif kind == "unreadable":
            status = "WARN"
            notes = "Could not decode file"
        elif findings:
            severe = [x for x in findings if not x[2]]
            if severe:
                status = "REVIEW"
                notes = "; ".join(f"{name}: {snip}" for name, snip, _ in severe)
            else:
                status = "PASS"
                notes = "; ".join(f"benign {name} mention" for name, _, _ in findings)

        rows.append((f, status, notes))
        if status == "REVIEW":
            flagged.append((f, notes))

    out = []
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out.append("# OSS Readiness & Privacy Audit\n")
    out.append(f"Generated: {now}\n")
    out.append("\n")
    out.append("## Scope\n")
    out.append("- Every git-tracked file was evaluated one-by-one.\n")
    out.append("- Text files were checked for secrets, telemetry/analytics keywords, and work/corporate references.\n")
    out.append("- Binary assets were inventoried and marked as scan-skipped.\n\n")
    out.append("## Automated Result\n")
    if flagged:
        out.append(f"- **REVIEW needed** in {len(flagged)} file(s).\n")
    else:
        out.append("- **No high-risk findings** detected by the automated scan.\n")
    out.append("\n")
    out.append("## Per-file Checklist\n")
    out.append("| File | Status | Notes |\n")
    out.append("|---|---|---|\n")
    for f, s, n in rows:
        n = n.replace("|", "\\|")
        out.append(f"| `{f}` | {s} | {n} |\n")

    report = REPO / "docs" / "oss-readiness-audit.md"
    report.write_text("".join(out), encoding="utf-8")
    print(f"Wrote {report.relative_to(REPO)} with {len(rows)} entries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
