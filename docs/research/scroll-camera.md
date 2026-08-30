*Synthesis of two research passes (2026-08-29); the full briefs are alongside.*

# Scroll Camera

*Superlemon · Motion design brief · 29 Aug 2026*

Why wheel scrolling still jitters at slow, ticked, fast and ramping speeds — and the model that replaces it. Synthesised from two sourced research passes (Chromium, Firefox APZ, WebKit, Android, Neovide, VS Code, Emacs, kitty, Zed, Flash & Hogan, Fischer et al.) checked against `SmoothViewportState`.

> **Verdict.** Not one shipping system models scroll motion as a sum of fixed-duration envelopes added per event. Every one keeps a single *camera* — one `(position, velocity)` — and retargets it; the incoming event moves the target and the follower carries its velocity through. Our model (`ContinuousScrollEnvelope`: one 180–480 ms minimum-jerk bell per row arrival, summed) fails in both directions: arrivals spaced wider than half a bell play as isolated 0→peak→0 pulses; arrivals closer than that stay unimodal but overshoot up to 2× per overlapping pair. No envelope duration escapes it. That single fact accounts for all four complaints.

## Where each complaint comes from

| Feel | Cause in the current model | Evidence |
|---|---|---|
| Jitter at very slow speed | Each row arrival is a rest-to-rest minimum-jerk bell: zero initial and terminal velocity are *boundary conditions* of the curve. Below ~1 row per 180 ms every row is its own start–stop. | Flash & Hogan 1985 (six boundary conditions, ẋ(0)=ẋ(T)=0); Fischer et al. TOCHI 2022: an open-loop model "cannot react to perturbations". |
| Line-by-line ticks | Same bell-per-row, plus tick mice deliver no velocity signal at all; the accumulator emits whole rows with no cadence model. | Neither Chromium nor Firefox estimates velocity from ticks; Firefox switches spring stiffness on inter-arrival timing instead. |
| Fast flicks | Superposition amplifies: two bells at d/T = 0.2 peak at 1.84× one bell, compounding across a burst. And `adaptiveEnvelopeDuration` stretches to 480 ms under bursty arrival — the exact inverse of Chromium, which shortens 200 → 100 ms as pending distance grows. | Derived threshold (single-peaked iff d ≤ T/2; verify before quoting numbers); Chromium `kInverseDelta*`. |
| Ramps up/down | No velocity continuity between bells and no ramp detector; `noteScrollInputPending` extends duration but cannot change slope. | Chromium `UpdateTarget` preserves velocity via the Bézier's first control point; Firefox's three-stiffness cadence rule is literally a ramp-down detector. |
| Content leaks into motion | Mostly solved already (grid_scroll rows as truth, edge-anchored bands, retained filmstrip). What remains: any frame classified atomic settles the envelope, so a repaint can still stop the camera. | Neovide rejected a content-diff heuristic ("would also disable smooth scrolling with relative line numbers"); nvim `ui.txt`: keep the grid separate from what is displayed. |

### What is already right

- Wheel steps are fire-and-forget `nvim_input_mouse` notifies — not the serialized-request trap Neovide fell into (neovide#2770).
- Ticks advance by `targetTimestamp`, not `timestamp`, as Apple prescribes; display gaps are detected.
- `mousescroll=ver:1,hor:1` in the managed config, so one row of finger travel is one row of motion (Neovide still ships the 3× gain bug).
- Retained filmstrip of pre-rasterised rows; repaints rebind rows without touching position; wire `grid_scroll` rows drive displacement with the semantic delta as provenance (and the earlier wire probe showed `scroll_delta` is wrap-aware).
- The cursor now hides during a gesture and is restored where nvim would have left it.

## The model

Four stages, each borrowed from the system that solved it best. The camera is a real-valued row position that the filmstrip renders at fractional offsets; nvim's whole-row viewport is a *constraint on which rows exist*, not on where the camera sits.

| Stage | Name | Description |
|---|---|---|
| A · Input | Velocity + phases | Impulse estimator over the raw wheel stream, 1€-smoothed. Gesture phases drive state; momentum deltas are consumed, not re-simulated. |
| B · Target | Predict, then reconcile | Requested rows move the target immediately; arrivals acknowledge. Discrepancies (end of buffer, folds) become a small residual, never a jump. |
| C · Follower | One critically damped spring | Analytic step at a fixed 120 Hz substep, interpolated readout. Stiffness switched on arrival cadence; velocity clamped to what the remaining distance can absorb. |
| D · Render | Fractional filmstrip | Exactly what exists today. Snap only at settle (0.01 row). Far jumps animate a fixed short tail, not the real distance. |

### A · Input

- **Velocity.** Android's *impulse* strategy is the default for the differential scroll axis precisely because it is delta-based and low-rate: `v = √2·√(Σ (vᵢ − vᵢ₋₁)·|vᵢ|)` over a 100 ms horizon, pointer assumed stopped after 40 ms. Smooth it with a 1€ filter (`fc = fcmin + β·|v̂|`): "if high-speed lag is a problem increase β; if slow-speed jitter is a problem decrease fcmin." Estimate from *input events only* — arrivals measure nvim's round trip, not the finger.
- **Phases** (currently ignored in `InputHostView.scrollWheel`): `phase == .began` → soft-start stiffness, reset cadence history; `phase == .ended && momentumPhase == .none` → finger lifted, settle; `momentumPhase == .began/.changed` → macOS has already applied deceleration, so its deltas move the target and we add no decay of our own (WebKit does exactly this on macOS).
- **Tick mice.** No velocity — nobody has a good one. Use Firefox's cadence rule (below) and WezTerm's accumulator hygiene: zero the remainder on reversal (done) and zero + round-away-from-zero after a 250 ms gap (not done).

### B · Target

Netcode's split applies cleanly: *predict your own input, interpolate the correction stream*. On a wheel step the target moves by the rows about to be requested; an unacknowledged count tracks what nvim has not yet confirmed; each arrival (`grid_scroll` rows, `win_viewport.scroll_delta` as provenance) decrements it. The difference between predicted and confirmed — the end-of-buffer clamp, a fold, an ignored step — feeds the same spring as a residual. Today's `noteScrollInputPending` hold is prediction without reconciliation; this is why the buffer edge overshoots and snaps back. Prediction is bounded by the retained filmstrip (2 × inner rows): the camera may run ahead only over rows it can draw.

Over SSH, add a *delay budget* for the correction stream only: render it `k·T̄` behind the newest arrival (k ≈ 1.5–2, T̄ the estimated arrival interval — Valve sizes `cl_interp` at twice the update interval so one lost update never starves the interpolator). This replaces the latency-adaptive envelope with a knob in units of arrival interval; its cost is exactly that much visual latency, invisible locally.

### C · Follower

```
// closed-form critically damped step, stable at any dt (Holden / Juckett / Neovide)
y   = damping / 2                 // damping = 4·ln2 / halflife
j0  = x - target
j1  = v + j0·y
e   = exp(-y·dt)
x   = e·(j0 + j1·dt) + target
v   = e·(v - j1·y·dt)
```

- **Retarget = move the target.** Position and velocity are never touched by an arrival (Neovide: `scroll_offset -= scroll_delta`, velocity untouched; Chromium: `new_target = target + delta`).
- **Stiffness by cadence** (Firefox `ComputeSpringConstant`, ζ = 1): first event or gap ≥ 120 ms → k = 1250 (soft start); gap ≥ 12 ms *and* ≥ 1.3× the previous gap → k = 2000 ("coming to a stop", settle faster); otherwise k = 1000. ω = √k, so these are ≈ 220 ms / 150 ms / 200 ms settle times. It is a ramp-down detector built from three numbers and needs no velocity estimate.
- **Velocity clamp** (Firefox bug 1846935): `|v| ≤ √k·|target − x|`. Carried velocity into a short remaining distance is the one way a velocity-continuous follower goes wrong; Chromium's equivalent is the `2.5·Δ/v` duration bound.
- **Fixed substep + interpolated readout** (Fiedler; Firefox `AxisPhysicsModel` at 1/120 s): integrate whole substeps from `targetTimestamp` deltas, render `lerp(prev, next, acc/dt)`. Kills variable-dt jitter where a spring is most sensitive — slow motion.
- **Far jumps**: Neovide's `scroll_animation_far_lines` (default 1): jump to within N rows and animate only those. `rotateForNewViewport`'s "isolated far jump = cut with a one-row cue" already does this; keep it.

### D · Render

Unchanged in structure. Two details: snap only at settle (Neovide: 0.01 rows), never mid-motion; and note that `pixelSnap` quantises the translation to device pixels — a 0.5 pt quantum on Retina, which Neovide's `.round()` is suspected of contributing to residual slow-speed jitter (neovide#3332). Worth an A/B once the follower is in; keep snapping if it wins on text sharpness.

## Parameters and their sources

| Knob | Start value | Source |
|---|---|---|
| Spring stiffness k (regular / start / stop) | 1000 / 1250 / 2000 | Firefox `general.smoothScroll.msdPhysics.*` |
| Cadence thresholds | ≥120 ms new gesture · ≥12 ms and ≥1.3× prev = slowdown | Firefox `ComputeSpringConstant` |
| Velocity clamp | \|v\| ≤ √k·\|remaining\| | Firefox `ClampVelocityToMaximum` |
| Substep | 1/120 s, frame delta clamped ≤ 0.25 s | Fiedler; Firefox `kFixedTimestep` |
| Settle threshold | 0.01 row | Neovide `animation_utils.rs` |
| Velocity horizon / stopped | 100 ms / 40 ms | AOSP `VelocityTracker` (impulse) |
| 1€ filter | fcmin 1 Hz, β 0, dcutoff 1 Hz → tune β up | Casiez et al. reference impl. |
| Remainder staleness | 250 ms, round away from zero | WezTerm macOS accumulator |
| Far-jump tail | 1 row | Neovide `scroll_animation_far_lines` |
| Remote delay budget | k = 1.5–2 arrival intervals; extrapolate ≤ 250 ms | Valve `cl_interp` / `cl_extrapolate_amount` |

Neovide's ω = 4/L and Unity SmoothDamp's ω = 2/smoothTime are the same knob at 2× different calibration — do not port tuned constants between formulations.

## Migration, smallest diff first

1. **Replace the envelope sum with one residual spring** — `ContinuousScrollEnvelope` → a single `(position, velocity)` follower per grid using the closed-form step above, target = accumulated row offset; arrivals move the target only. Add the cadence-switched stiffness and the velocity clamp. Keep `catchUp`, the filmstrip, far-jump handling and the classifier untouched. `slow` `tick` `fast` `ramp` — Highest confidence, smallest diff — Neovide shipped exactly this for "constantly speeding up and slowing down".
2. **Fixed substep and settle rule** — Integrate at 1/120 s from `targetTimestamp` deltas with interpolated readout; settle at 0.01 row; keep ticking through dropped frames rather than integrating one large dt. `slow`
3. **Read the gesture** — Plumb `phase`/`momentumPhase` from `scrollWheel` to the surface: soft start on `.began`, settle on non-momentum `.ended`, consume momentum deltas as target motion. Add the 250 ms remainder rule. `ramp` `tick`
4. **Predict and reconcile** — Move the target on the wheel step itself (bounded by filmstrip capacity), track unacknowledged rows, fold discrepancies into the residual. Retires `noteScrollInputPending`'s duration extension and fixes end-of-buffer snap-back. `fast`
5. **Remote delay budget** — Interpolate the arrival stream `k·T̄` behind, replacing `adaptiveEnvelopeDuration`. Only the correction stream — never the user's own input. `fast` `ramp`

### How to know it worked

The existing `SUPERLEMON_SCROLL_TRACE` ring records position, velocity and acceleration per tick. Three numbers per gesture make the complaints measurable: *velocity sign changes* (should be 0 for a one-direction gesture — today each slow row produces two), *peak/mean velocity ratio* during a steady drip (→ 1), and *settles per gesture* (→ 1). Drive with the real-nvim harness in `WrapScrollProbeTests` at three cadences — 400 ms, 80 ms, 10 ms per step — and with the latency-proxy transport for SSH.

## Risks and open questions

- **Filmstrip capacity bounds prediction.** The camera can only run ahead over rows it holds (2 × inner rows). Past that the honest options are to hold at the filmstrip edge or draw blank rows; Neovide chose "refuse to animate content it doesn't have".
- **Smoother rendering exposes the atomicity bug** (nvim#23609, fixed ≥ 0.9.2; bundled 0.12.4 is fine, remote hosts may not be). fredizzimo's warning: it gets *more* visible as motion improves.
- **Tick mice stay heuristic.** Cadence switching is the state of the art; there is no published velocity estimator for low-rate ticks.
- **Derived numbers.** The d ≤ T/2 threshold and the 2× amplification table are derivations consistent with Flash & Henis's data, not quoted results. The diagnosis does not depend on their exact values.
- **nvim `'smoothscroll'`** (skipcol sub-line scrolling) reports semantic delta 0 with nonzero wire rows; currently settles rather than animates. Test before enabling in the managed config.

## Sources

- Chromium [cc/animation/scroll_offset_animation_curve.cc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/cc/animation/scroll_offset_animation_curve.cc) — velocity-preserving `UpdateTarget`, inverse-delta duration, `2.5·Δ/v` bound; `ui/events/gestures/fling_curve.cc`; `ui/base/prediction/linear_resampling.cc`.
- Firefox `layout/generic/ScrollAnimationMSDPhysics.cpp`, `gfx/layers/AxisPhysicsMSDModel.cpp`, `AxisPhysicsModel.cpp`, `ScrollAnimationBezierPhysics.cpp`; prefs in `modules/libpref/init/StaticPrefList.yaml`; bug 1846935.
- WebKit `ScrollAnimationKinetic.cpp`, `ScrollAnimationSmooth.cpp`, `PlatformWheelEvent.h` (phase predicates). Apple WWDC 2018 §803 "Designing Fluid Interfaces" (projection + retarget); WWDC21 §10147 (`targetTimestamp`).
- AOSP `VelocityTracker.cpp` (impulse for the scroll axis). Casiez, Roussel & Vogel, "1€ Filter", CHI 2012 + reference implementation.
- Daniel Holden, [Spring-It-On](https://theorangeduck.com/page/spring-roll-call); Ryan Juckett, [Damped Springs](https://www.ryanjuckett.com/damped-springs/); Unity `Mathf.SmoothDamp` (GPG4 ch. 1.10); Fiedler, [Fix Your Timestep!](https://gafferongames.com/post/fix_your_timestep/).
- Neovide [rendered_window.rs](https://github.com/neovide/neovide/blob/main/src/renderer/rendered_window.rs), [animation_utils.rs](https://github.com/neovide/neovide/blob/main/src/renderer/animation_utils.rs), `mouse_manager.rs`; PR #1790, #1827, #2188; issues #1334, #2770, #2797, #3237, #3332.
- Neovim [ui.txt](https://github.com/neovim/neovim/blob/release-0.11/runtime/doc/ui.txt) (`win_viewport.scroll_delta`), `window.c::ui_ext_win_viewport`; issues #19227, #23609; PR #19270, #24182.
- VS Code [scrollable.ts](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/scrollable.ts); Emacs `pixel-scroll.el`; kitty PR #9330 (`pixel_scroll`); Zed `crates/editor/src/scroll.rs`; WezTerm #382/#3812 and its macOS accumulator.
- Flash & Hogan 1985, J. Neurosci. 5(7); Flash & Henis 1991, J. Cog. Neurosci. 3(3); Fischer et al., "Optimal Feedback Control for Modeling Human–Computer Interaction", ACM TOCHI 29(6) 2022, [arXiv:2110.00443](https://arxiv.org/pdf/2110.00443).
- Valve, *Source Multiplayer Networking* (entity interpolation, `cl_interp`); Gambetta, *Fast-Paced Multiplayer*.

Full research passes with quoted code: [smooth-scroll-browsers-and-os.md](./smooth-scroll-browsers-and-os.md) and [smooth-scroll-editors-and-terminals.md](./smooth-scroll-editors-and-terminals.md), alongside this file.
