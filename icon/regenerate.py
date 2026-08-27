import math, sys

OUT_DIR = sys.argv[1]
S = 512.0
AZ, EL = 34.0, 24.0


def basis(az, el):
    A, E = math.radians(az), math.radians(el)
    cam = (math.sin(A) * math.cos(E), -math.cos(A) * math.cos(E), math.sin(E))
    v = tuple(-c for c in cam)                      # camera -> origin

    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0])

    def norm(a):
        m = math.sqrt(sum(c * c for c in a))
        return tuple(c / m for c in a)

    r = norm(cross(v, (0, 0, 1)))
    u = norm(cross(r, v))
    return v, r, u


V, R, U = basis(AZ, EL)


def proj(p):
    return (sum(a * b for a, b in zip(p, R)), sum(a * b for a, b in zip(p, U)))


def depth(p):
    return sum(a * b for a, b in zip(p, V))        # larger = further along view dir


def box_faces(cx, cy, cz, w, d, h):
    """Axis-aligned box -> its 6 faces as (normal, [corners])."""
    x0, x1 = cx - w / 2, cx + w / 2
    y0, y1 = cy - d / 2, cy + d / 2
    z0, z1 = cz - h / 2, cz + h / 2
    return [
        ((0, 0, 1), [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]),   # top
        ((0, 0, -1), [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)]),  # bottom
        ((0, -1, 0), [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)]),  # front
        ((0, 1, 0), [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)]),
        ((-1, 0, 0), [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)]),
        ((1, 0, 0), [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]),
    ]


W, D, H = 2.30, 1.05, 0.86
GAP = 0.12
# chosen variant: staggered stack with corrugation ribs
STACKS = {
    "D2_stagger": [(-0.16, 0.0), (0.10, 0.0), (-0.06, 0.0)],
}


def build(offsets, ribs):
    """Returns (drawables, ribs) already projected; drawables sorted far -> near."""
    draws, riblines = [], []
    for i, (ox, oy) in enumerate(offsets):
        cz = (i - 1) * (H + GAP)
        for nrm, corners in box_faces(ox, oy, cz, W, D, H):
            if sum(a * b for a, b in zip(nrm, V)) >= 0:
                continue                                    # back-facing
            pts = [proj(c) for c in corners]
            dz = sum(depth(c) for c in corners) / 4.0
            kind = "top" if nrm[2] > 0.5 else "side"
            draws.append((dz, kind, pts))
            # corrugation: evenly spaced verticals on the long visible side
            if ribs and abs(nrm[1]) > 0.5:
                a, b, c2, d2 = corners
                for t in [k / (ribs + 1) for k in range(1, ribs + 1)]:
                    p0 = tuple(a[j] + (b[j] - a[j]) * t for j in range(3))
                    p1 = tuple(d2[j] + (c2[j] - d2[j]) * t for j in range(3))
                    riblines.append((dz - 1e-4, proj(p0), proj(p1)))
    draws.sort(key=lambda t: -t[0])
    return draws, riblines


STYLE = dict(
    bg=("#0A1020", "#04060E"),
    stroke=[("#7DFFF0", 0.0), ("#57B8FF", 0.5), ("#A45CFF", 1.0)],
    fill_top=("#153A66", "#0B1E3A"), fill_side=("#0D2646", "#06121F"),
    fill_op=0.85, sw=4.2, glow=6,
)

for name, offsets in STACKS.items():
    for ribs, suffix in ((3, "_ribs"),):
        draws, riblines = build(offsets, ribs)
        pts_all = [p for _, _, ps in draws for p in ps]
        xs = [p[0] for p in pts_all]
        ys = [p[1] for p in pts_all]
        span = max(max(xs) - min(xs), max(ys) - min(ys))
        sc = (S * 0.76) / span
        ox = S / 2 - (min(xs) + max(xs)) / 2 * sc
        oy = S / 2 + (min(ys) + max(ys)) / 2 * sc

        def f(p):
            return f"{ox + p[0]*sc:.2f},{oy - p[1]*sc:.2f}"

        defs = [
            f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{STYLE["bg"][0]}"/>'
            f'<stop offset="1" stop-color="{STYLE["bg"][1]}"/></linearGradient>',
            '<linearGradient id="sg" gradientUnits="userSpaceOnUse" x1="0" y1="40" '
            f'x2="0" y2="{S-40:.0f}">'
            + "".join(f'<stop offset="{o}" stop-color="{c}"/>' for c, o in STYLE["stroke"])
            + '</linearGradient>',
            f'<linearGradient id="ft" gradientUnits="userSpaceOnUse" x1="0" y1="40" '
            f'x2="0" y2="{S-40:.0f}">'
            f'<stop offset="0" stop-color="{STYLE["fill_top"][0]}"/>'
            f'<stop offset="1" stop-color="{STYLE["fill_top"][1]}"/></linearGradient>',
            f'<linearGradient id="fs" gradientUnits="userSpaceOnUse" x1="0" y1="40" '
            f'x2="0" y2="{S-40:.0f}">'
            f'<stop offset="0" stop-color="{STYLE["fill_side"][0]}"/>'
            f'<stop offset="1" stop-color="{STYLE["fill_side"][1]}"/></linearGradient>',
            f'<filter id="gl" x="-30%" y="-30%" width="160%" height="160%">'
            f'<feGaussianBlur stdDeviation="{STYLE["glow"]}" result="b"/>'
            f'<feMerge><feMergeNode in="b"/><feMergeNode in="b"/>'
            f'<feMergeNode in="SourceGraphic"/></feMerge></filter>',
        ]

        shapes = []
        for dz, kind, ps in draws:
            fill = "url(#ft)" if kind == "top" else "url(#fs)"
            shapes.append(f'<path d="M {" L ".join(f(p) for p in ps)} Z" '
                          f'fill="{fill}" fill-opacity="{STYLE["fill_op"]}"/>')
        for dz, p0, p1 in riblines:
            shapes.append(f'<path d="M {f(p0)} L {f(p1)}" fill="none" '
                          f'stroke-width="{STYLE["sw"]*0.5:.2f}" opacity="0.75"/>')

        grp = (f'<g stroke="url(#sg)" stroke-width="{STYLE["sw"]}" stroke-linejoin="round" '
               f'stroke-linecap="round" filter="url(#gl)">' + "".join(shapes) + '</g>')
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S:.0f} {S:.0f}" '
               f'width="{S:.0f}" height="{S:.0f}"><defs>{"".join(defs)}</defs>'
               f'<rect x="0" y="0" width="{S:.0f}" height="{S:.0f}" rx="112" fill="url(#bg)"/>'
               f'{grp}</svg>')
        p = f"{OUT_DIR}/davit_{name}{suffix}.svg"
        open(p, "w").write(svg)
        print(f"WROTE {p} faces={len(draws)} ribs={len(riblines)} bytes={len(svg)}", flush=True)
