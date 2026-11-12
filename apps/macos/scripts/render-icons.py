#!/usr/bin/env python3
"""Draws Boltty's icons: only lines and true circular arcs, every turn a tangent
fillet from a few radii, so nothing is sharp, crooked or curved by hand.

    scripts/render-icons.py        # writes Resources/Icons/*.svg
    scripts/render-icons.py DIR    # writes them elsewhere, to look at first
    scripts/check-icons.py         # then judges what was written

Change an icon here, never in its file. Standard library only.
"""
import math, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Icons")
os.makedirs(OUT, exist_ok=True)
HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="#000" '
        'stroke-width="1.425" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">')

# The only radii: J a joint, M a medium corner, B a container's corner; S small features only.
S, J, M, B = 0.75, 1.25, 2.0, 3.25


def n(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def p2(x, y):
    return f"{n(x)} {n(y)}"


def poly(points, r=J, closed=False, then=""):
    """Points are (x, y) or (x, y, radius). Open ends get no fillet; every other vertex must."""
    pts = [(q[0], q[1], q[2] if len(q) > 2 else r) for q in points]
    count = len(pts)
    idx = range(count) if closed else range(1, count - 1)
    joints = {}
    for i in idx:
        a, b, c = pts[(i - 1) % count], pts[i], pts[(i + 1) % count]
        ux, uy = b[0] - a[0], b[1] - a[1]
        vx, vy = c[0] - b[0], c[1] - b[1]
        lu, lv = math.hypot(ux, uy), math.hypot(vx, vy)
        ux, uy, vx, vy = ux / lu, uy / lu, vx / lv, vy / lv
        cross = ux * vy - uy * vx
        turn = math.atan2(abs(cross), ux * vx + uy * vy)
        t = b[2] * math.tan(turn / 2)
        joints[i] = dict(t=t, enter=(b[0] - ux * t, b[1] - uy * t),
                         leave=(b[0] + vx * t, b[1] + vy * t), r=b[2], sweep=1 if cross > 0 else 0,
                         lu=lu, lv=lv)
    # A fillet that does not fit is a drawing error, never squeezed.
    for i, j in joints.items():
        nxt = joints.get((i + 1) % count)
        room = j["lv"] - j["t"] - (nxt["t"] if nxt else 0)
        if room < -1e-3:
            sys.exit(f"A fillet does not fit at {pts[i][:2]}, by {-room:.3f}")
    if closed:
        d = "M" + p2(*joints[0]["leave"])
        order = list(range(1, count)) + [0]
    else:
        d = "M" + p2(pts[0][0], pts[0][1])
        order = list(range(1, count - 1))
    for i in order:
        j = joints[i]
        d += "L" + p2(*j["enter"]) + f"A{n(j['r'])} {n(j['r'])} 0 0 {j['sweep']} " + p2(*j["leave"])
    if closed:
        d += "Z"
    else:
        d += "L" + p2(pts[-1][0], pts[-1][1]) + then
    return d


def pol(cx, cy, r, a):
    return (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))


def arc(cx, cy, r, a0, a1):
    """Degrees, rising clockwise on screen. Split so a long sweep is never ambiguous."""
    d = "M" + p2(*pol(cx, cy, r, a0))
    sweep = 1 if a1 > a0 else 0
    steps = max(1, math.ceil(abs(a1 - a0) / 170))
    for s in range(1, steps + 1):
        d += f"A{n(r)} {n(r)} 0 0 {sweep} " + p2(*pol(cx, cy, r, a0 + (a1 - a0) * s / steps))
    return d


def line(*pts):
    return "M" + "L".join(p2(*q) for q in pts)


def rot(points, quarter):
    out = []
    for q in points:
        x, y = q[0] - 8, q[1] - 8
        for _ in range(quarter % 4):
            x, y = -y, x
        out.append((x + 8, y + 8) + tuple(q[2:]))
    return out


def P(*ds):
    return f'<path d="{"".join(ds)}"/>'


def C(cx, cy, r):
    return f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(r)}"/>'


def D(cx, cy, r):
    return f'<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(r)}" fill="#000" stroke="none"/>'


def R(x, y, w, h, r):
    return f'<rect x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="{n(r)}"/>'


def w(name, *parts):
    with open(os.path.join(OUT, name + ".svg"), "w") as f:
        f.write(HEAD + "".join(parts) + "</svg>\n")


APEX = J * (math.sqrt(2) - 1)  # how far a right-angled fillet stands inside its vertex
BOX = lambda: R(1.75, 1.75, 12.5, 12.5, B)

# Lines
w("plus", P(line((8, 2.25), (8, 13.75)), line((2.25, 8), (13.75, 8))))
w("xmark", P(line((3.25, 3.25), (12.75, 12.75)), line((12.75, 3.25), (3.25, 12.75))))
w("check", P(poly([(2.75, 8.25), (6.25, 11.75), (13.25, 4.25)])))
w("chart", P(line((3.25, 14.25), (3.25, 9.25)), line((8, 14.25), (8, 1.75)), line((12.75, 14.25), (12.75, 6))))
w("waveform", P(line((1.75, 6.5), (1.75, 9.5)), line((4.875, 4.25), (4.875, 11.75)), line((8, 1.75), (8, 14.25)),
                line((11.125, 4.25), (11.125, 11.75)), line((14.25, 6.5), (14.25, 9.5))))

# Chevrons: one drawing, turned
CHEV = [(2.75, 5.625), (8, 10.875), (13.25, 5.625)]
w("chevron-down", P(poly(CHEV)))
w("chevron-left", P(poly(rot(CHEV, 1))))
w("chevron-up", P(poly(rot(CHEV, 2))))
w("chevron-right", P(poly(rot(CHEV, 3))))
w("chevrons-up-down", P(poly([(4.75, 6.25), (8, 3), (11.25, 6.25)]), poly([(4.75, 9.75), (8, 13), (11.25, 9.75)])))

# Arrows
w("arrow-down", P(line((8, 2.25), (8, 13.5 - APEX)), poly([(3.25, 8.75), (8, 13.5), (12.75, 8.75)])))

# Circles
w("circle", C(8, 8, 6.25))
w("stop", R(4, 4, 8, 8, J).replace("/>", ' fill="#000"/>'))
w("circle-dashed", *[P(arc(8, 8, 6.25, k * 45 - 90 + 9.5, k * 45 - 90 + 35.5)) for k in range(8)])
w("circle-dotted", *[D(*pol(8, 8, 6.25, k * 30 - 90), 0.8) for k in range(12)])
w("check-circle", P(arc(8, 8, 6.25, -5, 293)), P(poly([(5, 7.75), (7.5, 10.25), (13.5, 3.75)])))
w("hex-grid", D(8, 8, 1.05), *[D(*pol(8, 8, 5.25, k * 60 - 90), 1.05) for k in range(6)])
w("power", P(line((8, 1.75), (8, 7.25))), P(arc(8, 8.25, 6, -50, 230)))

# Arrows round
def reload_head(a, r=6.25):
    ax, ay = pol(8, 8, r, a)
    # The head's fillet apex stands on the arc's end; its corner lies beyond, along the arc.
    tx, ty = -math.sin(math.radians(a)), math.cos(math.radians(a))
    return ax, ay, tx, ty


SYNC_HEAD = [(12.79, 1.7), (12.79, 3.95), (10.54, 3.95)]
w("sync", P(arc(8, 8, 6.25, 175, 315)), P(arc(8, 8, 6.25, -5, 135)),
  P(poly(SYNC_HEAD)), P(poly(rot(SYNC_HEAD, 2))))

# Containers
w("code", BOX(), P(poly([(6.75, 5.5), (4.25, 8), (6.75, 10.5)]), poly([(9.25, 5.5), (11.75, 8), (9.25, 10.5)])))
w("terminal", BOX(), P(poly([(4.75, 5.25), (7.5, 8), (4.75, 10.75)]), line((9, 10.75), (11.25, 10.75))))
w("film", BOX(), P(poly([(6.25, 5), (11.25, 8), (6.25, 11)], closed=True)))
w("photo", BOX(), D(5.5, 5.5, 1.15), P(poly([(4.25, 11.5), (8.5, 7.25), (11.75, 10.5)])))
w("keyboard", R(1.75, 3.25, 12.5, 9.5, B), D(5, 6.5, 0.85), D(8, 6.5, 0.85), D(11, 6.5, 0.85),
  P(line((5.75, 9.75), (10.25, 9.75))))
w("copy", R(1.75, 5, 9.25, 9.25, 2.5), P(poly([(5, 3), (5, 1.75, J), (14.25, 1.75, 2.5), (14.25, 11, J), (13, 11)])))
w("folder", P(poly([(1.75, 2.5, M), (6.25, 2.5), (8.25, 4.75), (14.25, 4.75, B), (14.25, 13.5, B), (1.75, 13.5, B)], closed=True)))
w("lock", R(2.75, 6.75, 10.5, 7.5, B), P(poly([(5, 6.75), (5, 1.75, 3), (11, 1.75, 3), (11, 6.75)])), D(8, 10.5, 1.1))

# Corners and dashes
CORNER = [(1.75, 5), (1.75, 1.75, B), (5, 1.75)]
corners = "".join(poly(rot(CORNER, k)) for k in range(4))
dash = "".join(line(*rot([(7, 1.75), (9, 1.75)], k)) for k in range(4))
w("region", P(corners, dash))
w("text-scan", P(corners, line((4.75, 6.25), (11.25, 6.25)), line((4.75, 9.75), (9, 9.75))))

# Bell
DOME = (3.75, 2, 4.25)
SIDES = [(12.25, 9, M), (13.75, 11.75), (2.25, 11.75), (3.75, 9, M)]
CLAPPER = line((6.75, 14.25), (9.25, 14.25))
top = pol(8, 6.25, 4.25, -70)
w("bell-badge", P(poly([(12.25, 6.25)] + SIDES + [DOME, (8, 2)],
                       then=f"A4.25 4.25 0 0 1 {p2(*top)}")), P(CLAPPER), D(12.5, 3.25, 1.5))
w("bell-slash",
  P(arc(8, 6.25, 4.25, -125, 0), line((12.25, 6.25), (12.25, 8.5))),
  P(poly([(3.75, 6.5), (3.75, 9, M), (2.25, 11.75), (9.25, 11.75)])), P(CLAPPER),
  P(line((2.5, 2.5), (13.5, 13.5))))

# Eye: two big arcs and two small ones, each tangent to the next
hw, c, top_y = 6.25, J, 3.75
half = 8 - top_y
d_ = ((hw - c) ** 2 - (half - c) ** 2) / (2 * (half - c))
big = d_ + half
ux, uy = (hw - c) / (big - c), d_ / (big - c)
tx, ty = hw - c + c * ux, c * uy  # tangent point's offsets from the middle
w("eye", P(f"M{p2(8 - tx, 8 - ty)}A{n(big)} {n(big)} 0 0 1 {p2(8 + tx, 8 - ty)}"
           f"A{n(c)} {n(c)} 0 0 1 {p2(8 + tx, 8 + ty)}"
           f"A{n(big)} {n(big)} 0 0 1 {p2(8 - tx, 8 + ty)}"
           f"A{n(c)} {n(c)} 0 0 1 {p2(8 - tx, 8 - ty)}Z"), D(8, 8, 1.7))

# Polygons, every vertex round
HEX = [pol(8, 8, 6.75, k * 60 - 90) for k in range(6)]
w("settings", P(poly(HEX, r=M, closed=True)), C(8, 8, 2.1))
w("warning", P(poly([(8, -0.25), (15.75, 13.75), (0.25, 13.75)], r=M, closed=True)),
  P(line((8, 5.75), (8, 8.75))), D(8, 11.25, 0.85))
w("pointer-rays", P(poly([(5.75, 5.75), (14.5, 9), (10.5, 10.5), (9, 14.5)], r=S, closed=True)),
  P(line((6, 1.75), (6, 3.25)), line((1.75, 6), (3.25, 6)), line((2.75, 2.75), (3.85, 3.85)),
    line((9.25, 2.75), (8.15, 3.85)), line((2.75, 9.25), (3.85, 8.15))))

# Star: a round tip and a round waist at every point
star = []
for k in range(4):
    star.append(pol(6.75, 9.25, 6.5, k * 90 - 90) + (S,))
    star.append(pol(6.75, 9.25, 2.2, k * 90 - 45) + (S,))

# Speaker
w("speaker", P(poly([(1.75, 5.75), (4.5, 5.75), (8.75, 2.25), (8.75, 13.75), (4.5, 10.25), (1.75, 10.25)], closed=True)),
  P(arc(8.75, 8, 2.75, -50, 50), arc(8.75, 8, 5.5, -50, 50)))

# People
w("speaking-person", C(6, 5.25, 2.75), P(arc(6, 14.25, 4.25, 180, 360)),
  P(arc(8, 5.25, 3.25, -45, 45), arc(8, 5.25, 5.75, -45, 45)))
w("people", C(5.75, 6.25, 2.25), P(arc(5.75, 14.25, 4, 180, 360)), C(11.25, 3.5, 1.75),
  P(arc(10.75, 12.25, 3.5, -70, 0)))

# Link: two hooks facing each other and a bar between them, all on one diagonal
def uv(u, v):
    k = math.sqrt(0.5)
    return (8 + (u + v) * k, 8 + (v - u) * k)


rr = 2.75
w("link", P(f"M{p2(*uv(1.25, rr))}L{p2(*uv(4.25, rr))}A{n(rr)} {n(rr)} 0 0 0 {p2(*uv(4.25, -rr))}L{p2(*uv(1.25, -rr))}",
            f"M{p2(*uv(-1.25, -rr))}L{p2(*uv(-4.25, -rr))}A{n(rr)} {n(rr)} 0 0 0 {p2(*uv(-4.25, rr))}L{p2(*uv(-1.25, rr))}",
            line(uv(-2.25, 0), uv(2.25, 0))))

# Music
w("music", C(4.25, 12, 2), C(11.25, 10.5, 2), P(poly([(6.25, 12), (6.25, 3.25), (13.25, 1.75), (13.25, 10.5)])))

# Compact: two corners and their diagonals
NE = [(9.25, 3.25), (9.25, 6.75), (12.75, 6.75)]
apex_d = APEX * math.sqrt(0.5)
NE_LINE = [(13.75, 2.25), (9.25 + apex_d, 6.75 - apex_d)]
w("compact", P(poly(NE)), P(line(*NE_LINE)), P(poly(rot(NE, 2))), P(line(*rot(NE_LINE, 2))))

# Brain: two lobes, stepped, every step round

# Keys
k = 1.75
w("key-command", P(f"M5.75 8L5.75 4A{k} {k} 0 1 0 4 5.75L12 5.75A{k} {k} 0 1 0 10.25 4L10.25 12"
                   f"A{k} {k} 0 1 0 12 10.25L4 10.25A{k} {k} 0 1 0 5.75 12Z"))
w("key-control", P(poly([(3.25, 10.125), (8, 5.375), (12.75, 10.125)])))
w("key-delete", P(poly([(5.25, 3.25), (14.25, 3.25, 2.5), (14.25, 12.75, 2.5), (5.25, 12.75), (1, 8)], closed=True)),
  P(line((7.75, 6.25), (11.25, 9.75)), line((11.25, 6.25), (7.75, 9.75))))
w("key-option", P(poly([(1.75, 3.5), (5, 3.5), (10.75, 12.5), (14.25, 12.5)])), P(line((10.25, 3.5), (14.25, 3.5))))
w("key-shift", P(poly([(8, 1), (15.25, 8.5, 1), (11, 8.5, 1), (11, 14.25), (5, 14.25), (5, 8.5, 1), (0.75, 8.5, 1)], closed=True)))
w("key-tab", P(line((1.75, 8), (11.75 - APEX, 8))), P(poly([(8, 4.25), (11.75, 8), (8, 11.75)])), P(line((14.25, 3), (14.25, 13))))

# An arrow's tip is two straight wings meeting on the stroke's round end, at 45 degrees
# either side of the way it points: a fillet there turned the tip into a blob.
def head(tip, heading, wing=3.0):
    return "".join(line(pol(tip[0], tip[1], wing, heading + 180 + side), tip) for side in (-45, 45))


# Circles tangent one to the next: (x, y, radius, 1 bulging out, 0 a notch). Tangent by
# construction, so an outline of bumps has no corner anywhere.
def chain(circles):
    d = ""
    count = len(circles)
    def touch(a, b):
        t = a[2] / (a[2] + b[2])
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    start = touch(circles[-1], circles[0])
    d = "M" + p2(*start)
    at = start
    for i, c in enumerate(circles):
        to = touch(c, circles[(i + 1) % count])
        a0 = math.atan2(at[1] - c[1], at[0] - c[0])
        a1 = math.atan2(to[1] - c[1], to[0] - c[0])
        span = (a1 - a0) % (2 * math.pi) if c[3] else -((a0 - a1) % (2 * math.pi))
        for s in range(1, 3):
            q = (c[0] + c[2] * math.cos(a0 + span * s / 2), c[1] + c[2] * math.sin(a0 + span * s / 2))
            d += f"A{n(c[2])} {n(c[2])} 0 0 {c[3]} " + p2(*q)
        at = to
    return d + "Z"


def notch(a, b, s, side):
    """The small circle tangent to bumps a and b, on the given side of the line between them."""
    mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
    dx, dy = b[0] - a[0], b[1] - a[1]
    l = math.hypot(dx, dy)
    h = math.sqrt((a[2] + s) ** 2 - (l / 2) ** 2)
    return (mx + side * h * dy / l, my - side * h * dx / l, s, 0)


# The ten drawn after the Return and microphone reference.
w("key-return", P(poly([(8, 3.25), (13.5, 3.25, 2.75), (13.5, 10, 2.75), (2.5, 10)])), P(head((2.5, 10), 180, 3.75)))
# The capsule's foot and the cradle share a centre, so the gap between them is one number.
w("mic", R(5, 1.5, 6, 8.5, 3), P(arc(8, 7, 5.75, 0, 180), line((8, 12.75), (8, 14.5))))
w("arrow-down-circle", C(8, 8, 6.5), P(line((8, 4.75), (8, 11.25)), head((8, 11.25), 90, 3.5)))
w("arrow-up-circle", C(8, 8, 6.5), P(line((8, 11.25), (8, 4.75)), head((8, 4.75), -90, 3.5)))
w("undo-circle", C(8, 8, 6.5),
  P(line((4.5, 6.5), (8.75, 6.5)), "A2.375 2.375 0 0 1 8.75 11.25", "L7.25 11.25", head((4.5, 6.5), 180, 2.83)))
RELOAD_END = -62
reload_tip = pol(8, 8.5, 5.5, RELOAD_END)
w("reload", P(arc(8, 8.5, 5.5, -8, 360 + RELOAD_END)), P(head(reload_tip, RELOAD_END + 90 - 8, 2.6)))
w("doc", P(poly([(3, 1.5, 2.5), (9.5, 1.5, 2.5), (13, 5, 2.5), (13, 14.5, 2.5), (3, 14.5, 2.5)], closed=True)),
  P(line((5.75, 8.5), (10.25, 8.5)), line((5.75, 11.25), (8.5, 11.25))))
# Turned half a circle about its middle, the bolt is itself. Its corners stand far outside
# the box so a soft fillet lands on the very tip and leaves the shoulders straight.
BOLT = [(10, -1.25, 1.25), (0.5, 10.5, 1.25), (6.25, 10.5, 1)]
w("bolt", P(poly(BOLT + [(16 - x, 16 - y, r) for x, y, r in BOLT], closed=True)))
# The maintainer's own drawing, kept to the letter: its stars are curves, which is why
# check-icons.py passes this file over. Change it by replacing these, not by redrawing.
w("sparkles", '<path d="M1.75 3.25H14.25M1.75 7.75H6.75M1.75 12.25H4.5"/>',
  '<path d="M11.6691 6.252C11.6891 6.17954 11.7322 6.11564 11.792 6.07011C11.8518 6.02457 11.9249 5.99994 12 6C12.0751 5.99994 12.1482 6.02457 12.208 6.07011C12.2678 6.11564 12.3109 6.17954 12.3309 6.252C12.489 6.8302 12.795 7.35723 13.2189 7.78114C13.6428 8.20496 14.1698 8.51101 14.748 8.66914C14.8205 8.68906 14.8844 8.73222 14.9299 8.792C14.9754 8.85178 15.0001 8.92486 15 9C15.0001 9.07514 14.9754 9.14822 14.9299 9.208C14.8844 9.26778 14.8205 9.31094 14.748 9.33086C14.1698 9.48899 13.6428 9.79504 13.2189 10.2189C12.795 10.6428 12.489 11.1698 12.3309 11.748C12.3109 11.8205 12.2678 11.8844 12.208 11.9299C12.1482 11.9754 12.0751 12.0001 12 12C11.9249 12.0001 11.8518 11.9754 11.792 11.9299C11.7322 11.8844 11.6891 11.8205 11.6691 11.748C11.511 11.1698 11.205 10.6428 10.7811 10.2189C10.3572 9.79504 9.8302 9.48899 9.252 9.33086C9.17954 9.31094 9.11564 9.26778 9.0701 9.208C9.02457 9.14822 8.99994 9.07514 9 9C8.99994 8.92486 9.02457 8.85178 9.0701 8.792C9.11564 8.73222 9.17954 8.68906 9.252 8.66914C9.8302 8.51101 10.3572 8.20496 10.7811 7.78114C11.205 7.35723 11.511 6.8302 11.6691 6.252Z" fill="#000" stroke="none"/>',
  '<path d="M8.378 11.252C8.40764 11.1776 8.45895 11.1138 8.52527 11.0688C8.5916 11.0239 8.66989 10.9999 8.75 11C8.83011 10.9999 8.9084 11.0239 8.97473 11.0688C9.04105 11.1138 9.09236 11.1776 9.122 11.252C9.22325 11.5064 9.37535 11.7374 9.569 11.931C9.76256 12.1246 9.99361 12.2768 10.248 12.378C10.3224 12.4076 10.3862 12.4589 10.4312 12.5253C10.4761 12.5916 10.5001 12.6699 10.5 12.75C10.5001 12.8301 10.4761 12.9084 10.4312 12.9747C10.3862 13.0411 10.3224 13.0924 10.248 13.122C9.99361 13.2232 9.76256 13.3754 9.569 13.569C9.37535 13.7626 9.22325 13.9936 9.122 14.248C9.09236 14.3224 9.04105 14.3862 8.97473 14.4312C8.9084 14.4761 8.83011 14.5001 8.75 14.5C8.66989 14.5001 8.5916 14.4761 8.52527 14.4312C8.45895 14.3862 8.40764 14.3224 8.378 14.248C8.27675 13.9936 8.12465 13.7626 7.931 13.569C7.73744 13.3754 7.50639 13.2232 7.252 13.122C7.17757 13.0924 7.11376 13.0411 7.06883 12.9747C7.0239 12.9084 6.99992 12.8301 7 12.75C6.99992 12.6699 7.0239 12.5916 7.06883 12.5253C7.11376 12.4589 7.17757 12.4076 7.252 12.378C7.50639 12.2768 7.73744 12.1246 7.931 11.931C8.12465 11.7374 8.27675 11.5064 8.378 11.252Z" fill="#000" stroke="none"/>')
BR = 2.6
BUMPS_L = [(5.35, 4.1, BR, 1), (3.95, 8, BR, 1), (5.35, 11.9, BR, 1)]
top_l, mid_l, bot_l = BUMPS_L
top_r, mid_r, bot_r = [(16 - x, y, r, b) for x, y, r, b in BUMPS_L]
OUTLINE = [top_r, notch(top_r, mid_r, 0.6, 1), mid_r, notch(mid_r, bot_r, 0.6, 1), bot_r,
           notch(bot_r, bot_l, 0.6, 1), bot_l, notch(bot_l, mid_l, 0.6, 1), mid_l,
           notch(mid_l, top_l, 0.6, 1), top_l, notch(top_l, top_r, 0.6, 1)]
w("brain", P(chain(OUTLINE)), P(line((8, 3), (8, 13))))
