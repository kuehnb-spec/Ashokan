# Ashokan App Icon — Design Brief

Goal: professional and Mac-native at first glance, distinctive and a little
poetic at second glance. The name is a Catskills reservoir; the app is a
place where documents become clear.

## Design constraints (apply to every concept)

- macOS squircle (rounded-square) canvas, subtle top-down gradient and soft
  inner shadow, in the style of Apple's own document apps (Pages, Notes,
  TextEdit).
- Must read clearly at 16 px (Dock minimum) and reward a close look at 512 px.
- No text/lettering smaller than a single large glyph; no photorealism.
- Palette anchor: deep reservoir blue-greens (#1B4B5A → #2E7D8A range) with
  paper white; one warm accent allowed (golden hour on the water).

## Concept 1 — "The Reservoir Page" (recommended)

A white document page fills the squircle. The lower third of the page is
calm water — a flat horizon line, deep blue-green, with a soft reflection of
Catskill mountain silhouettes that exist *only in the reflection* (the sky
above the waterline is just clean page). Two faint text lines at the top
suggest a document. The reflection is the WYSIWYG metaphor: the page shows
you what the markup means, the way still water shows you the mountains.

> Prompt: "macOS app icon, rounded square, minimalist: a clean white document
> page whose lower third is calm dark teal reservoir water with a subtle
> mountain-range reflection in the water only, two faint gray text lines at
> the top of the page, flat modern Apple design language, soft gradients,
> no text, no border, centered, 1024x1024"

## Concept 2 — "Angle-Bracket Mountains"

Two overlapping Catskill peaks drawn as oversized `<` and `>` angle brackets,
deep blue-green, mirrored in a strip of water below; a small warm sun (or
document dot) between them. Code and landscape in one mark — instantly "HTML"
to developers, just mountains to everyone else.

> Prompt: "macOS app icon, rounded square: two minimalist mountain peaks
> subtly shaped like < and > angle brackets in deep teal, reflected in a
> narrow band of water at the base, small warm golden sun between the peaks,
> flat geometric Apple-style design, soft gradient sky, 1024x1024"

## Concept 3 — "The Caret Ripple"

A white page viewed straight-on; where a text cursor (a thin vertical caret)
touches the page, concentric ripple rings spread outward as if the caret were
a pebble dropped in still water. Quietly says "writing here is fluid."

> Prompt: "macOS app icon, rounded square: minimalist white document page
> with a thin blue text cursor in the center, concentric water ripple rings
> emanating from the cursor across the page surface, flat modern style, deep
> teal accents, 1024x1024"

## Concept 4 — "The Nib and the Slash"

A classic fountain-pen nib, drawn geometrically, whose ink slit is a forward
slash — the `</` of a closing tag. Paper-white nib on reservoir blue-green.
Writing-first, code-visible.

> Prompt: "macOS app icon, rounded square: geometric white fountain pen nib
> centered on deep teal gradient background, the nib's ink slit shaped as a
> subtle forward slash like a closing HTML tag, flat minimal Apple design
> language, 1024x1024"

## Concept 5 — "A on the Water"

A confident serif capital "A" (writing, authorship, Ashokan) standing on a
waterline, its reflection below rendered as angle brackets — the letterform
reflects as code. Monogram simplicity with a story.

> Prompt: "macOS app icon, rounded square: elegant white serif capital letter
> A standing on a calm waterline over deep teal water, its reflection in the
> water subtly formed of angle bracket shapes, flat minimal design, soft
> gradient, 1024x1024"

## After the image exists

Give Claude the final 1024×1024 PNG and it will: downscale the full size set
(16–1024 @1x/@2x), assemble `AppIcon.icns` / an asset catalog, wire it into
project.yml, and rebuild.

## Ship checklist (beyond the icon)

1. **Apple Developer ID** ($99/yr) → sign + notarize so others can open it
   without right-click gymnastics. Until then it runs fine locally.
2. Release-configuration build in build.sh.
3. Make the GitHub repo public (license is already MIT).
4. README screenshots + a small landing page (an HTML file, naturally —
   dogfood).
5. Sparkle (or GitHub Releases + manual download) for updates.
6. Later: Homebrew cask for `brew install --cask ashokan`.
