#!/usr/bin/env python3
"""Read-only queries over Explorer diagnostics. No network, repair, inference or source-chat access."""
import argparse
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

MAX_LINE = 16384

def read_bytes(path, limit=128 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("not a bounded regular file")
        with os.fdopen(fd, "rb", closefd=False) as handle:
            data = handle.read(limit + 1)
        if len(data) > limit:
            raise ValueError("file exceeds read limit")
        return data
    finally:
        os.close(fd)

def load(path):
    return json.loads(read_bytes(path))

def sessions(root):
    if (root / "session.json").is_file():
        return [root]
    return sorted(p for p in root.iterdir() if not p.is_symlink() and p.is_dir() and (p / "session.json").is_file())

def records(path, gaps):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("not a regular event file")
        offset = 0
        while True:
            line = stream.readline(MAX_LINE + 1)
            if not line:
                return
            start = offset
            offset += len(line)
            if len(line) > MAX_LINE:
                while not line.endswith(b"\n"):
                    line = stream.readline(MAX_LINE + 1)
                    offset += len(line)
                    if not line:
                        break
                gaps["oversized"] += 1
                if not line.endswith(b"\n"):
                    gaps["partial"] += 1
                continue
            if not line.endswith(b"\n"):
                gaps["partial"] += 1
                continue
            try:
                value = json.loads(line)
                if not isinstance(value, dict) or value.get("schema") != 1:
                    gaps["unknown_schema"] += 1
                    continue
                if not (isinstance(value.get("session"), str) and type(value.get("sequence")) is int and type(value.get("uptimeNS")) is int and isinstance(value.get("event"), str) and isinstance(value.get("fields"), dict)):
                    raise ValueError("invalid record shape")
            except (ValueError, UnicodeError):
                gaps["malformed"] += 1
                continue
            yield value, {"file": path.name, "byte_offset": start, "byte_length": len(line)}

def summarize(root):
    output = []
    for session in sessions(root):
        gaps = collections.Counter()
        events = collections.Counter()
        timings = collections.defaultdict(lambda: {"count": 0, "sum_ms": 0., "max_ms": 0.})
        previous = 0
        wrong_identity = nonincreasing = 0
        manifest = load(session / "session.json")
        identity = manifest["identity"]
        for path in sorted(session.glob("events-*.jsonl")):
            for value, _ in records(path, gaps):
                if value["session"] != identity["session"]:
                    wrong_identity += 1
                seq = value["sequence"]
                if not isinstance(seq, int) or seq <= previous:
                    nonincreasing += 1
                else:
                    if previous and seq > previous + 1:
                        gaps["sequence_gaps"] += seq - previous - 1
                    previous = seq
                events[value["event"]] += 1
                duration = value["fields"].get("duration_ms")
                if isinstance(duration, (int, float)) and 0 <= duration < float("inf"):
                    t = timings[value["event"]]
                    t["count"] += 1
                    t["sum_ms"] += duration
                    t["max_ms"] = max(t["max_ms"], duration)
        for t in timings.values():
            t["mean_ms"] = t.pop("sum_ms") / t["count"]
        closed = None
        try:
            closed = load(session / "closed.json")
        except (OSError, ValueError):
            pass
        try:
            status = load(session / "status.json")
        except (OSError, ValueError):
            status = {"unavailable": True}
        output.append({"identity": identity, "completion": "recorder closed; subsequent process exit cause not established" if closed and closed.get("cleanShutdown") else "unclosed; may be active or interrupted; exit cause unknown", "coverage": manifest.get("coverage", []), "status_checkpoint": status, "final_status": closed, "events": events, "timings": timings, "recovery": gaps, "wrong_session_records": wrong_identity, "nonincreasing_sequences": nonincreasing})
    return {"sessions": output, "interpretation": "Observed records and arithmetic only. Missing end events can mean loss, cancellation, interruption, or an uninstrumented path. Durations cover named boundaries, not causal attribution."}

def verify(root):
    receipt = load(root / "bundle.json")
    checks = []
    for file in receipt["files"]:
        relative = Path(file["path"])
        if relative.is_absolute() or ".." in relative.parts or any((root / Path(*relative.parts[:n])).is_symlink() for n in range(1, len(relative.parts) + 1)):
            raise ValueError("unsafe manifest path")
        data = read_bytes(root / relative, 8 * 1024 * 1024 + MAX_LINE)
        checks.append({"path": str(relative), "matches": len(data) == file["bytes"] and hashlib.sha256(data).hexdigest() == file["sha256"]})
    return {"verified": all(c["matches"] for c in checks), "files": checks, "omissions": receipt.get("omissions", [])}

def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return stamp.timestamp() if stamp.tzinfo is not None else None
    except ValueError:
        for form in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
            try:
                return datetime.datetime.strptime(value, form).timestamp()
            except ValueError:
                pass
        return None

def parse_ips(data):
    # macOS reports may append a non-JSON System Profile after the second JSON object.
    text = data.decode("utf-8").lstrip()
    decoder = json.JSONDecoder()
    first, end = decoder.raw_decode(text)
    remaining = text[end:].lstrip()
    if isinstance(first, dict) and "pid" in first:
        report, trailing = first, remaining
    else:
        report, end = decoder.raw_decode(remaining)
        trailing = remaining[end:]
    if not isinstance(report, dict) or not isinstance(report.get("bundleInfo"), dict) or not isinstance(report.get("usedImages"), list) or not all(isinstance(x, dict) for x in report["usedImages"]):
        raise ValueError("unsupported report identity shape")
    return report, len(trailing.encode("utf-8"))

def correlate(root, reports):
    identities = [load(p / "session.json")["identity"] for p in sessions(root)]
    matches, scanned, skipped, trailing_bytes = [], 0, 0, 0
    # Explicit opt-in to this directory; do not search the rest of the computer.
    paths = sorted(reports.glob("CodexChats*.ips"), key=lambda p: p.name, reverse=True)
    for path in paths[:256]:
        try:
            data = read_bytes(path, 8 * 1024 * 1024)
            report, trailing = parse_ips(data)
            trailing_bytes += trailing
            scanned += 1
            info = report.get("bundleInfo", {})
            launch, captured = parse_time(report.get("procLaunch")), parse_time(report.get("captureTime"))
            for identity in identities:
                # PID alone, temporal proximity, and an unclosed session are insufficient.
                uuid = identity.get("binaryUUID")
                images = report.get("usedImages", [])
                image_matches = uuid and any(x.get("uuid", "").lower() == uuid.lower() and x.get("name") == report.get("procName") for x in images)
                start = identity.get("processStart")
                if (report.get("pid") == identity["pid"] and image_matches and info.get("CFBundleIdentifier") == identity["bundleID"] and str(info.get("CFBundleVersion")) == identity["build"] and info.get("CFBundleShortVersionString") == identity["version"] and launch is not None and start is not None and abs(launch - start) <= .01 and captured is not None and captured >= identity["recorderStart"] - .01):
                    matches.append({"session": identity["session"], "report": path.name, "sha256": hashlib.sha256(data).hexdigest(), "evidence": ["pid", "kernel process start within 10ms", "main executable UUID", "bundle ID", "version", "build", "capture after recorder start"], "exception": report.get("exception"), "termination": report.get("termination")})
        except (OSError, ValueError, TypeError, KeyError):
            skipped += 1
    return {"matches": matches, "scanned": scanned, "unreadable_or_unsupported": skipped, "trailing_report_bytes_not_parsed": trailing_bytes, "unscanned": max(0, len(paths) - 256), "scope": "CodexChats*.ips in the explicitly supplied directory only; no match is not proof of no crash"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["summary", "events", "verify", "correlate"])
    parser.add_argument("root", type=Path)
    parser.add_argument("--event")
    parser.add_argument("--session")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--reports", type=Path)
    args = parser.parse_args()
    if args.command == "events":
        gaps, count = collections.Counter(), 0
        for session in sessions(args.root):
            if args.session and session.name != args.session:
                continue
            for path in sorted(session.glob("events-*.jsonl")):
                for value, source in records(path, gaps):
                    if args.event and value["event"] != args.event:
                        continue
                    if count >= max(1, args.limit):
                        print(json.dumps({"limit_reached": True, "recovery": gaps}), file=sys.stderr)
                        return
                    print(json.dumps({"record": value, "source": source}, separators=(",", ":")))
                    count += 1
        print(json.dumps({"returned": count, "recovery": gaps}), file=sys.stderr)
    else:
        if args.command == "correlate" and args.reports is None:
            parser.error("correlate requires --reports DIRECTORY")
        result = {"summary": lambda: summarize(args.root), "verify": lambda: verify(args.root), "correlate": lambda: correlate(args.root, args.reports)}[args.command]()
        print(json.dumps(result, indent=2, sort_keys=True))
        if args.command == "verify" and not result["verified"]:
            sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": type(error).__name__, "detail": str(error)}), file=sys.stderr)
        sys.exit(2)
