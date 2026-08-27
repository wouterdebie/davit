# Davit — menu bar icon (template image)

Monochrome glyph for the menu bar extra: three staggered container outlines, echoing
the app icon. Pure black + alpha, no colour or gradient — macOS inverts it for
light/dark, tinting and the highlighted state.

## Files

| file | |
|---|---|
| `DavitTemplate.svg` | master, 36×36 viewBox, stroked outlines |
| `DavitTemplate.png` / `@2x` / `@3x` | 18 / 36 / 54 px |
| `DavitTemplate-ribs-alt.*` | outlines plus corrugation ribs — more literally "shipping container", busier at 18px |
| `DavitTemplate-light-alt.*` | three thin solid bars — lightest option, least container-like |

Verified pure black (`max_rgb = 0.000`).

## Using it

The `…Template` suffix matters: AppKit auto-detects a template image by **name**, so
keep it. Asset catalog → image set named `DavitTemplate`, **Render As: Template Image**
(Xcode 12+ also takes the SVG directly with Preserve Vector Data).

```swift
let image = NSImage(named: "DavitTemplate")!
image.isTemplate = true
image.size = NSSize(width: 18, height: 18)
statusItem.button?.image = image
```

Don't tint it — template images take their colour from the system, which is what makes
them adapt automatically.

## Why outlines, not solid bars

Two shapes were rejected on purpose:

**Three aligned bars is the hamburger-menu icon.** Universally read as "menu", which is
an active collision in a menu bar. The stagger is what breaks that association — it is
load-bearing, not decoration.

**Solid staggered bars** read as a heavy black slab at 18px and looked like a list, not
containers. Hollow outlines carry the same silhouette at much lower visual weight and
say "box" immediately.

(Ink-coverage numbers are a poor guide here — thick outlines measure about the same
coverage as solid fills, ~0.48, while looking far lighter. Judge these by eye at 18px
and 36px against a real menu bar background.)

## Sizes

Sharp at @2x (36px), which is what every current Mac renders. At @1x (18px) the
outlines get chunky but stay legible. If the default reads too heavy in practice, use
`DavitTemplate-light-alt`; if it reads too generic, use `DavitTemplate-ribs-alt`.

## Regenerating

Geometry is plain rectangles — no dependency on the app-icon pipeline:

- three 1.0 × 0.30 rects, gap 0.10, x-offsets `(-0.10, +0.09, -0.05)` (the stagger)
- fitted into a 36×36 box with 1.6 padding, stroke width 3.0, round joins

Matching the app icon's stagger direction keeps the two recognisably the same product.
