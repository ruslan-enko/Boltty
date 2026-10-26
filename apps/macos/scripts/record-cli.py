#!/usr/bin/env python3
"""Records a line-protocol CLI talking, for an adapter test to replay.

Boltty's adapters were long tested against fixtures written from what the
parser expected, and twice that hid a bug the real CLI showed at once
(AGENTS.md, *What the sweeps found*). t3code records its providers instead and
replays the recording through the real adapter; this is the same idea for
Boltty's line protocols (Claude Code's stream-json, Codex's app-server, ACP).

    scripts/record-cli.py OUT.jsonl --cwd DIR --wait 30 -- claude --print ... \
        < input.jsonl

Each line of stdin is sent to the CLI in turn — a line `{"_wait": 7}` waits
seven seconds before the next instead — and every line the CLI prints is kept.
OUT.jsonl holds one record per line, in order:

    {"dir": "in",  "t": 0.00, "line": "..."}    what was sent
    {"dir": "out", "t": 1.23, "line": "..."}    what the CLI printed

`Tests/BolttyTests/Fixtures/replay-cli.py` plays it back. A recording is the
CLI's own words, so read it before committing it: it can hold paths, an
e-mail, a system prompt. Strip what is the person's, keep what is the CLI's.
"""
import argparse, json, subprocess, sys, threading, time

if "--" not in sys.argv:
    sys.exit("usage: record-cli.py OUT.jsonl [--cwd DIR] [--wait S] -- CLI ARGS...")
split = sys.argv.index("--")
parser = argparse.ArgumentParser()
parser.add_argument("out")
parser.add_argument("--cwd", default=".")
parser.add_argument("--wait", type=float, default=20, help="seconds to keep recording after the last input")
args = parser.parse_args(sys.argv[1:split])
argv = sys.argv[split + 1:]

process = subprocess.Popen(argv, cwd=args.cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, bufsize=1)
start = time.time()
records = []
lock = threading.Lock()

def keep(direction, line):
    with lock:
        records.append({"dir": direction, "t": round(time.time() - start, 2), "line": line})

def read():
    for line in process.stdout:
        keep("out", line.rstrip("\n"))

reader = threading.Thread(target=read, daemon=True)
reader.start()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    pause = json.loads(line).get("_wait") if line.startswith('{"_wait"') else None
    if pause is not None:
        time.sleep(pause)
        continue
    keep("in", line)
    process.stdin.write(line + "\n")
    process.stdin.flush()
time.sleep(args.wait)
process.terminate()
reader.join(timeout=2)
with open(args.out, "w") as out:
    for record in records:
        out.write(json.dumps(record) + "\n")
print(f"{len(records)} lines -> {args.out}", file=sys.stderr)
