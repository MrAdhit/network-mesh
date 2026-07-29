# Filament

The design language of the mesh desktop app. Named for what the product is: thin paths of
light between machines, several at once, the brightest one carrying the traffic.

Filament is not Material, not Cupertino, not Fluent. Nothing in the app should read as a
skinned version of someone else's toolkit. The reference point is a **network instrument**:
a thing an operator glances at to know, within a second, whether the mesh is healthy and
which path is winning. Dense, calm, precise. The app never decorates; every colored pixel
is a statement about state.

## Principles

1. **State is the decoration.** The resting UI is near-monochrome. Color appears only to
   report path/backhaul state or to mark the one primary action on a screen. If everything
   is up, the app is a quiet field of green-flecked gray; if something is down, the red is
   unmissable because nothing competes with it.
2. **Numbers are the heroes.** RTTs, addresses, loss percentages get the mono face, tabular
   alignment, and the largest type on the screen. Labels are small and recede.
3. **Depth is light.** Surfaces are lit from above, like instruments in a dark room: a
   1px top-edge highlight, a fill that breathes slightly lighter at the top, a soft
   ambient shadow underneath, and a barely-there phosphor haze in the window background.
   Never a Material elevation ramp, never a ripple — but never dead-flat either. The
   signal color is allowed to bloom: live indicators and the hero cast a soft glow into
   their surroundings.
4. **The CLI's voice.** Terse, honest, sentence case. Everything the app writes for
   itself — rail labels, titles, buttons, field labels, badges, status words, toasts,
   explainers — starts with a capital and continues lowercase, with proper nouns and
   initialisms in their real form: Cloudflare, Tailscale, Zero Trust, RTT, EWMA, API,
   IP, URL, CIDR. `meshd` and `meshctl` are the names of programs and stay lowercase
   wherever they land, sentence-start included. Empty states say what the CLI says, in
   that voice ("No peers known yet."). Anything that arrives over the wire — daemon and
   control-plane errors, backhaul detail lines, node and path names — is quoted verbatim
   and never restyled. Never Title Case Headers, never exclamation marks.
5. **Signal travels.** Nothing teleports and nothing pops. Every change arrives from
   somewhere and settles like a damped needle: fast attack, soft landing, the faintest
   overshoot on interactive elements, never a cartoon bounce. Motion only ever announces a
   state change — if it means nothing, it does not move. See **Motion**.

## Color

Dark is the primary theme; light is a first-class sibling. All values are tokens — no
literal colors in widget code.

### Dark

| token          | value     | use |
|----------------|-----------|-----|
| `bg`           | `#0B0E11` | window background |
| `surface`      | `#11151A` | panels, rail |
| `surfaceHigh`  | `#171C23` | hover, pressed, input fills |
| `hairline`     | `#222A33` | default borders, dividers |
| `hairlineHigh` | `#2E3844` | focused/hovered borders |
| `text`         | `#E6EBF0` | primary text |
| `textDim`      | `#98A5B3` | labels, secondary |
| `textFaint`    | `#5C6B7A` | disabled, units, placeholders |
| `signal`       | `#46C98C` | up, winning path, primary action |
| `signalDim`    | `#2E6B4F` | up but not winning |
| `caution`      | `#D9A544` | degraded, lossy, expiring |
| `alarm`        | `#D96552` | down, errors, destructive |
| `link`         | `#6AA1D8` | links, relay/info accents |

### Light

| token          | value     |
|----------------|-----------|
| `bg`           | `#F2F4F7` |
| `surface`      | `#FBFCFD` |
| `surfaceHigh`  | `#EDF0F4` |
| `hairline`     | `#D9E0E7` |
| `hairlineHigh` | `#B9C4CF` |
| `text`         | `#1A222B` |
| `textDim`      | `#5A6875` |
| `textFaint`    | `#93A0AC` |
| `signal`       | `#1F9E68` |
| `signalDim`    | `#8FC9AE` |
| `caution`      | `#B07E1E` |
| `alarm`        | `#C24A37` |
| `link`         | `#3B76B4` |

Depth tokens, both themes:

| token       | dark                          | light                        | use |
|-------------|-------------------------------|------------------------------|-----|
| `edgeLight` | white at 6%                   | white at 90%                 | 1px inner top edge of panels |
| `haze`      | `signal` at 4%, radial        | `signal` at 3%, radial       | window-background aurora, top-left |
| `shade`     | black at 35%, blur 24, y 8    | `#1A222B` at 10%, blur 20, y 6 | ambient shadow under panels |
| `bloom`     | owner color at 25%, blur 10   | owner color at 20%, blur 8   | glow of live dots, winner bars, the hero number |

Panel fill is a vertical gradient from `surfaceHigh`-leaning at the top to `surface` at
the bottom — quiet enough that you only notice it when it is gone. Sparklines fill the
area under the line with `signal` fading to transparent. Glows bloom, they never flare:
if a screenshot looks like a neon sign, it is overdone.

## Typography

- **UI face:** the platform system font (San Francisco / Segoe / system sans). We are not
  bundling a brand font; the identity lives in layout and color, not a typeface.
- **Data face:** platform mono stack — `SF Mono, Menlo, Consolas, DejaVu Sans Mono,
  monospace`. Every number, address, key, hash, and unit uses the data face.
- Scale (px): 11 labels (with +0.5 tracking, `textDim`), 13 base, 14 emphasized, 15/600
  section titles, 18–20 stat-tile numbers, 44 the single headline number on Overview.
  Weights: 400/500/600. Values outrank their labels: a reading is set two steps larger
  than the label above it, and the eye should land on numbers first everywhere.
- Units are set in `textFaint` at one size smaller than their number: `12.4 ms`.

## Shape and space

- Spacing grid: 4px. Panel padding 20. Gaps between panels 16.
- Radius: 10 on panels, 6 on controls, 999 on pills/dots.
- Borders 1px `hairline` plus the `edgeLight` top edge; focus ring is 1.5px `signal` at
  40% opacity, offset 1px.
- The window: left rail 220px (72px collapsed), content column max-width 960px,
  **centered** in the remaining space — the app composes like a page, it does not hug a
  corner of a void.

## Composition

A screen is not a stack of identical boxes. Three shapes, mixed:

- **The hero.** Overview's identity block floats directly on the window background — no
  panel, no border. Large triad with bloom, the node's name at section size, and the
  44px headline RTT rolling like a meter, its unit faint beside it. Panels begin below.
- **Stat tiles.** Short facts (address, uptime, peers, node count) are compact tiles in a
  row — label on top, big mono value under it — not label-value form rows. A tile row
  reads at a glance; a form has to be read.
- **Panels.** Everything else, in the lit-from-above style, sized to content: two
  backhaul cards share a row, a table takes the full column. Vary the rhythm; never
  ship a screen that is one full-width box after another five times.

## The path triad

The signature mark of the app. Every peer, everywhere it appears, carries three short
vertical bars in fixed order: **direct · cloudflare · tailscale**.

- Winning path: full-height bar, `signal`, glow.
- Up, not winning: 60% height, `signalDim`.
- Lossy (loss ≥ 5%): 60% height, `caution`.
- Down: 30% height outline, `alarm`.
- Unknown/not configured: 30% height, `hairlineHigh`.

Bars are 3×12px at rest, 2px gap. The triad is also the app's status motif: the rail's
daemon indicator and the Overview headline reuse it at larger sizes. Hovering a triad
names the paths in a tooltip.

## Iconography

Hand-drawn line icons, 16×16 grid, 1.5px stroke, round caps, drawn as `CustomPainter`
paths in code — no icon font, no Material glyphs. The set is small on purpose:
pulse (overview), nodes (peers), globe (network), gear (settings), key, copy, refresh,
ping/radar, chevron, close, warning, power, eye/eye-off. Icons inherit text color.

## Components (the kit)

All widgets are ours, prefixed `Mesh`, built on the Flutter widgets layer — the app must
not import Material or Cupertino for anything visible. Core kit:

- `MeshApp` — WidgetsApp root, theme provider, focus/shortcut plumbing.
- `MeshScaffold` — rail + content. Rail: app mark, nav items (icon + label, active item
  gets a 2px `signal` left edge and `surfaceHigh` fill), bottom status block showing the
  daemon triad and session chip.
- `MeshPanel` — the card: `surface` fill, `hairline` border, radius 6, optional header
  row (13px/600 title left, actions right).
- `MeshButton` — primary (signal fill, `bg`-colored text), secondary (transparent,
  hairline border), destructive (alarm text/border), ghost (text only). Height 28,
  radius 4, no ripple: hover brightens fill, press darkens.
- `MeshTextField` — `surfaceHigh` fill, hairline border, focus ring; mono option for
  keys/addresses; obscured option with eye toggle for secrets.
- `MeshStatusDot` — 8px dot + optional glow; the word next to it says the state.
- `MeshBadge` — pill, 11px, quiet fill; used for "Expired", "Not configured", counts.
- `MeshTable` — hairline-separated rows, 11px `textDim` column headers, mono data cells,
  hover `surfaceHigh`; rows can expand in place.
- `MeshSparkline` — 1.5px `signal` polyline of RTT history, no axes, faint min/max band.
- `MeshDialog` — overlay confirm: dimmed backdrop (`bg` at 60%), centered panel, the
  destructive action styled destructive and never default-focused.
- `MeshToast` — bottom-right transient notices, one at a time.
- `MeshToggle`, `MeshSelect`, `MeshTooltip`, `MeshCopyable` (click-to-copy with a brief
  "Copied" confirmation in place).

## Motion

The metaphor is the product's own: light moving along a filament. Three tempos, defined
once in `FilamentMotion` and used everywhere — no ad-hoc durations or curves in widgets.

- **touch** — 120ms ease-out. Hover fills, press states, focus rings.
- **drift** — 240ms emphasized decelerate. Screen changes, panel fades, anything that
  travels without being grabbed.
- **settle** — a spring (stiffness ≈ 550, damping ratio ≈ 0.85; retargetable mid-flight).
  The rail spark, dialogs, toasts, chevrons, triad bars, row expansion. The overshoot is
  barely perceptible; if you notice the bounce, it is tuned wrong.

The choreography:

- **The traveling spark.** The rail's active edge is one light that slides along the rail
  to the destination you pick and settles there. Content follows with spatial continuity:
  moving down the rail drifts the old screen up and the new one in from below, moving up
  reverses it, 12px and a fade, on `drift`.
- **Panel arrival.** The first time a screen shows, its panels rise 8px and fade in with a
  30ms stagger, top to bottom. Never replayed by polls or rebuilds — arrival happens once.
- **Instrument needles.** Numeric readings roll toward their new value over 300ms (the
  hero RTT ticks like a meter, it does not blink). Sparklines extend continuously. Triad
  bars spring between heights and crossfade between state colors.
- **The handoff pulse.** When a peer's winning path changes, the glow leaves the old bar
  and lands on the new one as one ~400ms pulse. Failover is the product's whole point;
  it is the one moment allowed to draw the eye.
- **Buttons** press to 0.98 scale (transform only, never layout). **Dialogs** scale in
  from 0.96 behind a backdrop fade on `settle`; **toasts** spring up 12px.
- **Interruptible always.** A second click mid-flight retargets the animation from its
  current position; nothing queues, nothing finishes a dead transition first.
- **Reduced motion.** When the platform asks (`MediaQuery.disableAnimations`), every
  tempo collapses to a 90ms crossfade and the handoff pulse becomes an instant swap.
  Meaning survives; travel does not.

## Behavior

- Live data ticks every 2s; changed values crossfade, they never jump or flash.
- Copy affordances on every address, key, and id.
- Destructive actions (leave network, remove node) always confirm via `MeshDialog`,
  restating the consequence in the daemon's own terms ("its address is free for the next
  node").
- Errors from the daemon or control plane are shown verbatim in mono, inside the panel
  that caused them, never as blocking modals.
- Keyboard: full tab traversal, Enter submits, Esc dismisses dialogs, ⌘C copies focused
  copyable.
