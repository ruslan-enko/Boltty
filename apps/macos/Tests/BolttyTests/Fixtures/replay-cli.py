#!/usr/bin/env python3
"""Plays a recording made by `scripts/record-cli.py` back as the CLI.

Run as the adapter's executable with the recording in `BOLTTY_REPLAY`. Each
line the adapter writes stands for the next recorded input, by order, not by
content: what the CLI printed after that input is printed again, with the same
spacing in time (capped at `BOLTTY_REPLAY_GAP` seconds, default 0.3), up to
the next recorded input. The adapter's own request ids are put back where the
recording had the recorder's, so a reply answers the request that was sent.
What the CLI printed after the last input is played out too, which is how a
turn the CLI opened by itself reaches the test.
"""
import json, os, sys, time

records = [json.loads(line) for line in open(os.environ["BOLTTY_REPLAY"]) if line.strip()]
gap = float(os.environ.get("BOLTTY_REPLAY_GAP", "0.3"))
inputs = [i for i, r in enumerate(records) if r["dir"] == "in"]

def ids_in(line):
    try:
        frame = json.loads(line)
    except ValueError:
        return {}
    ids = {}
    for key in ("request_id", "id"):
        if key in frame:
            ids[key] = frame[key]
    if isinstance(frame.get("response"), dict) and "request_id" in frame["response"]:
        ids["response.request_id"] = frame["response"]["request_id"]
    return ids

played = set()

def answers(record, ids):
    """Whether an output line is the reply to the input whose ids these are:
    a control response naming its request, or a JSON-RPC result by its id."""
    try:
        frame = json.loads(record["line"])
    except ValueError:
        return False
    inner = frame.get("response") if isinstance(frame.get("response"), dict) else {}
    if "request_id" in ids and inner.get("request_id") == ids["request_id"]:
        return True
    return "id" in ids and frame.get("id") == ids["id"] and "method" not in frame

def play(start, stop, swap, ids=None):
    # A reply recorded after later inputs — a recorder that did not wait for
    # it — still answers its own request, first.
    if ids:
        for index, record in enumerate(records):
            if index not in played and record["dir"] == "out" and answers(record, ids):
                played.add(index)
                line = record["line"]
                for old, new in swap.items():
                    line = line.replace(json.dumps(old), json.dumps(new))
                print(line, flush=True)
                break
    last = None
    for index in range(start, stop):
        record = records[index]
        if record["dir"] != "out" or index in played:
            continue
        played.add(index)
        if last is not None:
            time.sleep(min(gap, max(0, record["t"] - last)))
        last = record["t"]
        line = record["line"]
        for old, new in swap.items():
            line = line.replace(json.dumps(old), json.dumps(new))
        print(line, flush=True)

# `readline`, never `for line in sys.stdin`: the iterator reads ahead, and a
# first line that is a handshake waits for a second that never comes — the
# adapter is waiting on the answer before it sends anything else.
log = open(os.environ["BOLTTY_REPLAY_LOG"], "a") if os.environ.get("BOLTTY_REPLAY_LOG") else None
n = -1
while True:
    line = sys.stdin.readline()
    if log:
        log.write(f"{time.time():.2f} in {line[:100]!r}\n"); log.flush()
    if not line:
        break
    n += 1
    if n >= len(inputs):
        break
    recorded = ids_in(records[inputs[n]]["line"])
    sent = ids_in(line)
    swap = {recorded[k]: sent[k] for k in recorded if k in sent and recorded[k] != sent[k]}
    stop = inputs[n + 1] if n + 1 < len(inputs) else len(records)
    play(inputs[n] + 1, stop, swap, recorded)
    if n + 1 == len(inputs):
        # Everything after the last input, then stay open as the CLI would.
        time.sleep(3600)
