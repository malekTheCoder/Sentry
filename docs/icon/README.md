# App icon

`sentry-icon-source.svg` is the original artwork as supplied: a 720×720 rounded
body at (180,180) on a 1080×1080 canvas, sitting on an opaque `#f2efe9`
backdrop. That backdrop is presentation padding for showing the icon off — it
is *not* part of the icon, and shipping it would have produced an icon with a
visible cream square around it at every size.

Two derived variants are committed alongside it, because macOS and iOS want
genuinely different things:

**`sentry-icon-macos.svg`** — the backdrop is dropped and the body is placed on
Apple's macOS icon grid: 824×824 centred in 1024×1024, leaving the ~100px
transparent margin the platform expects (macOS does *not* mask app icons, so
the rounded corners and the drop shadow have to be in the artwork itself). The
source art's corner radius already matched almost exactly — 165/720 = 22.9%
against Apple's 185.4/824 = 22.5% — so no reshaping was needed, only scaling.

**`sentry-icon-ios.svg`** — full-bleed square, because iOS and watchOS apply
their own corner mask and reject any icon containing an alpha channel. Squaring
it off meant more than dropping `rx`/`ry` from the body: the clip path, the
hairline rim stroke, and the top-corner highlight arc all traced the rounded
outline and would have drawn a phantom rounded edge inside the square. The drop
shadow is also removed — it falls outside the shape, which is meaningless once
the art reaches the edges.

## Regenerating

The PNGs in the asset catalogs were rendered from these SVGs with QuickLook
(`qlmanage -t -s <size>`), which is the only SVG rasteriser present on this
machine — no `rsvg-convert`, `inkscape`, or ImageMagick. Each macOS size is
rendered from the SVG at its target size rather than downscaled from one large
raster: the dial's fine tick marks alias badly when a 1024 render is reduced to
16pt.

The iOS/watchOS PNG is additionally passed through an alpha flattener
(composite over `#f3f0eb`, re-encode as truecolour-without-alpha) because
App Store validation rejects icons with an alpha channel, and no image library
is available here to do it more conventionally.
