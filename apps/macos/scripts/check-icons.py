#!/usr/bin/env python3
"""Judges the icons as drawn, knowing nothing of scripts/render-icons.py: only lines
and arcs, tangent at every joint, and the ink clear of the box's edge. A file in
DRAWN_BY_HAND is someone's own drawing and is passed over.

    scripts/check-icons.py         # Resources/Icons
    scripts/check-icons.py DIR

Exits 1 on any problem. Standard library only.
"""
import math, os, re, sys

folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Icons")
DRAWN_BY_HAND = {"sparkles.svg"}
names = sorted(f for f in os.listdir(folder) if f.endswith(".svg") and f not in DRAWN_BY_HAND)
NUM = r"-?\d*\.?\d+"
bad = 0
radii = {}
for name in names:
    svg = open(os.path.join(folder, name)).read()
    half = 1.425 / 2
    box = [99, 99, -99, -99]

    def grow(x, y, m):
        box[0], box[1] = min(box[0], x - m), min(box[1], y - m)
        box[2], box[3] = max(box[2], x + m), max(box[3], y + m)

    for cx, cy, r, rest in re.findall(r'<circle cx="([^"]+)" cy="([^"]+)" r="([^"]+)"([^>]*)>', svg):
        m = float(r) + (0 if "fill" in rest else half)
        grow(float(cx) - m, float(cy) - m, 0)
        grow(float(cx) + m, float(cy) + m, 0)
    for x, y, w, h, r in re.findall(r'<rect x="([^"]+)" y="([^"]+)" width="([^"]+)" height="([^"]+)" rx="([^"]+)"', svg):
        radii.setdefault(float(r), set()).add(name)
        grow(float(x), float(y), half)
        grow(float(x) + float(w), float(y) + float(h), half)
    for d, rest in re.findall(r'<path d="([^"]+)"([^>]*)>', svg):
        half = 0 if 'stroke="none"' in rest else 1.425 / 2
        if re.search(r"[CcQqSsTtHhVv]|[a-z]", d):
            print(f"{name}: not lines and arcs: {d[:40]}")
            bad += 1
            continue
        for sub in re.findall(r"M[^M]+", d):
            closed = sub.rstrip().endswith("Z")
            tokens = re.findall(r"[MLA]|" + NUM + "|Z", sub)
            i, cur, segs = 0, None, []
            while i < len(tokens):
                t = tokens[i]
                if t == "M":
                    cur = (float(tokens[i + 1]), float(tokens[i + 2]))
                    i += 3
                elif t == "L":
                    to = (float(tokens[i + 1]), float(tokens[i + 2]))
                    if math.hypot(to[0] - cur[0], to[1] - cur[1]) > 2e-3:
                        ang = math.atan2(to[1] - cur[1], to[0] - cur[0])
                        segs.append((ang, ang))
                    grow(*cur, half)
                    grow(*to, half)
                    cur = to
                    i += 3
                elif t == "A":
                    r = float(tokens[i + 1])
                    sweep = tokens[i + 5] == "1"
                    to = (float(tokens[i + 6]), float(tokens[i + 7]))
                    radii.setdefault(r, set()).add(name)
                    mx, my = (cur[0] + to[0]) / 2, (cur[1] + to[1]) / 2
                    dx, dy = to[0] - cur[0], to[1] - cur[1]
                    l = math.hypot(dx, dy)
                    if l < 2e-3:
                        i += 8
                        continue
                    hh = math.sqrt(max(r * r - l * l / 4, 0))
                    large = tokens[i + 4] == "1"
                    sign = 1 if large != sweep else -1
                    cx, cy = mx - sign * hh * dy / l, my + sign * hh * dx / l
                    s = 1 if sweep else -1
                    a0 = math.atan2(cur[1] - cy, cur[0] - cx) + s * math.pi / 2
                    a1 = math.atan2(to[1] - cy, to[0] - cx) + s * math.pi / 2
                    segs.append((a0, a1))
                    th0 = math.atan2(cur[1] - cy, cur[0] - cx)
                    th1 = math.atan2(to[1] - cy, to[0] - cx)
                    span = (th1 - th0) % (2 * math.pi) if sweep else -((th0 - th1) % (2 * math.pi))
                    for k in range(25):
                        th = th0 + span * k / 24
                        grow(cx + r * math.cos(th), cy + r * math.sin(th), half)
                    cur = to
                    i += 8
                else:
                    i += 1
            pairs = list(zip(segs, segs[1:])) + ([(segs[-1], segs[0])] if closed and segs else [])
            for a, b in pairs:
                turn = abs((b[0] - a[1] + math.pi) % (2 * math.pi) - math.pi)
                if math.degrees(turn) > 1.0:
                    print(f"{name}: kink of {math.degrees(turn):.1f}° in {sub[:36]}")
                    bad += 1
    over = [v for v in (box[0], box[1], 16 - box[2], 16 - box[3]) if v < 0.45]
    if over:
        print(f"{name}: ink too near the edge: {[round(v, 2) for v in box]}")
        bad += 1
print(f"{len(names)} files, {bad} problems")
print("radii:", {k: len(v) for k, v in sorted(radii.items())})
sys.exit(1 if bad else 0)
