*Research pass, 2026-08-29, sources read directly; see scroll-camera.md for the synthesis.*

# Smooth scrolling on a row-quantized model — a sourced brief

For: a macOS Neovim GUI that quantizes wheel deltas to whole rows, round-trips them through nvim, and
animates the row displacement as a pixel translation over a retained filmstrip. Complaints addressed:
jitter at slow speeds **[slow]**, at line-by-line ticks **[tick]**, at fast flicks **[fast]**, during
speed ramps **[ramp]**, and content affecting motion **[content]**.

---

## 1. Neovide — the closest prior art

### 1.1 It animates a *residual*, not a queue of tweens

[`src/renderer/rendered_window.rs`](https://github.com/neovide/neovide/blob/main/src/renderer/rendered_window.rs).
`scroll_animation.position` is **in lines** and holds the remaining displacement between where the
grid already is and where the screen is drawn. It is never a tween from A to B. `flush()`:

```rust
let scroll_delta = self.scroll_delta;
self.scrollback_lines.rotate(scroll_delta);          // grid snaps instantly
self.scrollback_lines.clone_from_iter(inner_view);
if scroll_delta != 0 {
    let mut scroll_offset = self.scroll_animation.position;
    let max_delta = self.scrollback_lines.len().saturating_sub(self.grid_size.height as usize);
    if scroll_delta.unsigned_abs() > max_delta { /* far scroll, see 1.3 */ }
    else {
        scroll_offset -= scroll_delta as f32;        // fold into existing residual
        // "we can't let it drift too far, since the buffer size is limited"
        scroll_offset = scroll_offset.clamp(-(max_delta as f32), max_delta as f32);
    }
    self.scroll_animation.position = scroll_offset;
}
```

Velocity is untouched by an arrival — the spring simply has further to go. **Mapping:** one animator
with one `(position, velocity)` for the whole gesture, so a slow drip of rows is one continuous decay,
not a train of isolated 0→peak→0 pulses. **[slow] [tick] [ramp]**

Caveat: that `clamp` truncates the animation when rows arrive faster than the spring settles —
architectural, and exactly the SSH-burst case.

### 1.2 A critically damped spring, analytic form

[`src/renderer/animation_utils.rs`](https://github.com/neovide/neovide/blob/main/src/renderer/animation_utils.rs):

```rust
let zeta = 1.0;
// The omega is calculated so that the destination is reached with a 2% tolerance in
// animation_length time.
let omega = 4.0 / (zeta * animation_length);
let a = self.position;
let b = self.position * omega + self.velocity;
let c = (-omega * dt).exp();
self.position = (a + b * dt) * c;
self.velocity = c * (-a * omega - b * dt * omega + b);
if self.position.abs() < 0.01 { self.reset(); false } else { true }
```

- **Analytic, not Euler** → unconditionally stable at any `dt`. (Identical to Juckett's closed form,
  §4.2.)
- **ω = 4/L** because `e⁻⁴ ≈ 0.018`: exposes a spring as a duration-like knob. Default
  `scroll_animation_length = 0.3 s` ⇒ ω ≈ 13.3 rad/s, τ = 75 ms.
- Settle threshold is **0.01 lines**, so the snap-to-row is invisible and happens only at rest.

### 1.3 Content is deliberately excluded from motion

`scrollback_lines: RingBuffer<Option<Rc<RefCell<RenderedLine>>>>` sized `2 * grid_height` holds
pre-rasterized Skia pictures. Drawing is pure translation — integer part selects rows, fraction
translates:

```rust
let scroll_offset_lines  = self.scroll_animation.position.floor();
let scroll_offset        = scroll_offset_lines - self.scroll_animation.position;
let scroll_offset_pixels = (scroll_offset * grid_scale.height()).round();
```

Row repaints update a cached picture without touching `position`. For scrolls beyond the buffer,
Neovide refuses to animate content it doesn't have: it jumps to within `far_lines` of the destination,
blanks the vacated rows, and animates only those. Documented ([neovide.dev/configuration.html](https://neovide.dev/configuration.html),
default **1**): *"When scrolling more than one screen at a time, only this many lines at the end of the
scroll action will be animated."* **Mapping:** distance-proportional animation is what makes flicks
smear; cap it. **[fast]**

### 1.4 Input quantization — and the `mousescroll` gain bug

[`src/window/mouse_manager.rs`](https://github.com/neovide/neovide/blob/main/src/window/mouse_manager.rs)
accumulates fractional deltas in grid units and emits one `<ScrollWheelDown>` per integer crossing;
`handle_pixel_scroll` just divides pixels by cell height into the same path. nvim then multiplies by
`'mousescroll'` (default `ver:3`), so **one row of finger travel produces three rows of motion**.
`mousescroll` appears nowhere in Neovide's source. Neovide reads winit's `PixelDelta` vs `LineDelta`
but never macOS `momentumPhase`, and has **no input-velocity estimator at all**. **[tick]**

### 1.5 History — what broke and what fixed it

The single most on-point sentence, from fredizzimo's
[PR #1790](https://github.com/neovide/neovide/pull/1790) (81 comments, folded into #1977):

> "The actual scrolling algorithm also had to be changed, since everything works a bit smoother, and
> the simple easing based scrolling didn't look good at all, **constantly speeding up and slowing
> down**."

That is the reported symptom, and the fix was the residual spring. The `grid_scroll` vs `win_viewport`
question was argued twice from both sides; it ended when MDeiml established in
[#1334](https://github.com/neovide/neovide/issues/1334) that **`grid_scroll` is only emitted when the
movement is less than a full screen**, and his upstream PR (neovim#19270) added display-line
`scroll_delta`. Neovide switched in PR #1827, explicitly disabling smooth scroll for viewport events
lacking `scroll_delta`: *"This way we only do it if we know it is correct."*

[#2797](https://github.com/neovide/neovide/issues/2797) (open) is the content case: a progress bar
pinned to the bottom of a `:terminal` "bouncing up and down so rapidly it probably warrants an
epilepsy warning." The proposed content-diff heuristic was rejected by fredizzimo with a decisive
counterexample — *"would also disable smooth scrolling in windows with relative line numbers"*, where
every line's content changes every scroll. **Don't infer motion from content.** **[content]**

Still open and directly relevant: [#3332](https://github.com/neovide/neovide/issues/3332) line
snapping at end of scroll (*thin* — no maintainer reply, but corroborated by the `floor()` on input and
`.round()` on output); [#2770](https://github.com/neovide/neovide/issues/2770) remote unresponsiveness
— *"`nvim-rs` doesn't support rpc notifications, so we are forced to send requests, which has to wait
for the response for the previous command… neovim requires one command per step"*;
[#3237](https://github.com/neovide/neovide/issues/3237) macOS stutter — *"When the vblank is missed, a
swap is allowed immediately, and the following frame is also animated immediately because we are
late"*, fix named as `CAMetalDisplayLink` pacing. Also PR #2188: run animation early in the frame, and
**keep ticking the animation on dropped frames**.

---

## 2. Neovim's protocol — what the authoritative source promises

[`runtime/doc/ui.txt`](https://github.com/neovim/neovim/blob/release-0.11/runtime/doc/ui.txt):

> `["grid_scroll", …]` Scroll a region of `grid`. **This is semantically unrelated to editor
> |scrolling|**, rather this is an optimized way to say "copy these screen cells".

> `["win_viewport", grid, win, topline, botline, curline, curcol, line_count, scroll_delta]` …
> `scroll_delta` contains how much the top line of a window moved since `win_viewport` was last
> emitted. **It is intended to be used to implement smooth scrolling. For this purpose it only counts
> "virtual" or "displayed" lines, so folds only count as one line.** When scrolling more than a full
> screen it is an approximate value.
>
> All updates, such as `grid_line`, in a batch affects the new viewport, despite the fact that
> `win_viewport` is received after the updates. Applications implementing, for example, smooth
> scrolling should take this into account and **keep the grid separated from what's displayed on the
> screen and copy it to the viewport destination once `win_viewport` is received.**

The computation, [`src/nvim/window.c::ui_ext_win_viewport`](https://github.com/neovim/neovim/blob/release-0.11/src/nvim/window.c):

```c
delta -= win_text_height(wp, cur_topline, wp->w_skipcol, last_topline, last_skipcol, NULL);
...
delta += last_topfill;  delta -= wp->w_topfill;
```

`delta` is an **integer count of screen rows** from `win_text_height`, already accounting for soft
wrap, folds (one row), diff filler, and `w_skipcol` — i.e. `'smoothscroll'` sub-line positions.
**This is display-space, so its meaning is independent of document content.** **[content]**

Two nvim issues shaped this:
- [#19227](https://github.com/neovim/neovim/issues/19227) — `win_viewport` gave *buffer* lines, which
  diverge from displayed lines under folds. Closed by PR #19270, which added `scroll_delta`.
- [#23609](https://github.com/neovim/neovim/issues/23609) — atomicity. fredizzimo's trace: batch 1 is
  `GridLine{grid:4}`, `WindowViewport{scroll_delta:3.0}`, `Flush`; batch 2 is `Scroll{rows:3}`, the
  three new `GridLine`s, `WindowViewport{scroll_delta:0.0}`, `Flush`. *"We have now scrolled the
  scrollback buffer, but the current view has not been updated… there are now three empty lines, that
  we haven't received yet."* Frequency with folds on screen: *"perhaps every 10th scroll event."*
  And the warning that matters most: **"It's not too bad due to the slow rendering we currently have,
  but when the rendering and everything is smooth it's very noticeable."** Fixed upstream by PR #24182
  (nvim ≥ 0.9.2), which is the source comment *"The win_viewport command is delayed until the next
  flush when there are pending updates."* A related instance is still open as
  [neovide#2278](https://github.com/neovide/neovide/issues/2278).

---

## 3. Other editors and terminals

### 3.1 VS Code / Monaco — fixed-duration ease-out, restarted on retarget

[`src/vs/base/common/scrollable.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/scrollable.ts).
Duration 125 ms; `completion = (now - startTime) / duration`; `easeOutCubic(t) = 1 - (1-t)³`. Long
scrolls get a two-segment composition (the "teleport the middle" trick):

```ts
private _initAnimation(from, to, viewportSize): IAnimation {
	const delta = Math.abs(from - to);
	if (delta > 2.5 * viewportSize) {
		stop1 = from + 0.75 * viewportSize;  stop2 = to - 0.75 * viewportSize;   // sign-flipped if from > to
		return createComposed(createEaseOutCubic(from, stop1), createEaseOutCubic(stop2, to), 0.33);
	}
	return createEaseOutCubic(from, to);
}
```

Retargeting is the weak part — and it is the design the target app currently resembles:

```ts
public combine(from, to, duration) { return SmoothScrollingOperation.start(from, to, duration); }

public static start(from, to, duration) {
	// +10 / -10 : pretend the animation already started for a quicker response to a scroll request
	duration = duration + 10;
	const startTime = Date.now() - 10;
	return new SmoothScrollingOperation(from, to, startTime, duration);
}
```

`combine` **discards the old animation** and restarts an ease-out from the live position. `easeOutCubic`
has maximum slope at t=0, so every event takes a velocity *jump*; the ±10 ms hack exists to skip the
flattest part of the curve. The alternative `reuseAnimation: true` path keeps the original `from` and
`startTime` and moves only `to` — strictly more continuous, and the cheapest possible improvement to a
fixed-duration scheme. Note VS Code chose ease-*out* (fast start) rather than a min-jerk-style
ease-in-out, precisely because the latter feels laggy under repeated input.

### 3.2 Chromium / Blink — retarget while preserving velocity (best of the tween designs)

[`cc/animation/scroll_offset_animation_curve.cc`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/cc/animation/scroll_offset_animation_curve.cc).
Fixed 150 ms (`kConstantDuration 9.0 / kDurationDivisor 60.0`), cubic-Bézier ease-in-out
`(0.42, 0, 0.58, 1)`. `UpdateTarget`:

```cpp
  // Adjust the slope of the new animation in order to preserve the velocity of
  // the old animation.
  double velocity = CalculateVelocity(t);
  double new_slope = velocity * (new_duration.InSecondsF() / MaximumDimension(new_delta));
  timing_function_ = GetEasingFunction(new_slope);
  initial_value_ = current_position;  target_value_ = new_target;
```

```cpp
std::unique_ptr<TimingFunction> EaseInOutWithInitialSlope(const CubicBezierPoints& cp, double slope) {
  slope = std::clamp(slope, -1000.0, 1000.0);
  // Scale the first control point with `slope`.
  return CubicBezierTimingFunction::Create(cp.x1, cp.x1 * slope, cp.x2, cp.y2);
}
```

C¹ continuity across arbitrarily many retargets. And the guard that names the target app's symptom:

```cpp
  // Estimate how long it will take to reach the new target at our present
  // velocity, with some fudge factor to account for the "ease out".
  double bound = (new_delta_max_dimension / velocity) * 2.5f;
  ...
  // Use the velocity-based duration bound when it is less than the constant
  // segment duration. This minimizes the "rubber-band" bouncing effect when
  // |velocity| is large and |new_delta| is small.
  return std::min(EaseInOutSegmentDuration(...), VelocityBasedDurationBound(old_delta, velocity, new_delta));
```

*"Rubber-band bouncing when velocity is large and new_delta is small"* **is** jitter on a speed ramp
and at slow ticks. **[ramp] [slow]**

### 3.3 Emacs `pixel-scroll-precision-mode` — separates velocity estimation from animation

[`lisp/pixel-scroll.el`](https://github.com/emacs-mirror/emacs/blob/master/lisp/pixel-scroll.el).
Three ideas on a line-quantized display engine:

**(a) Remainder carry.** `pixel-scroll-precision-interpolate` is a *linear* ramp over
`interpolation-total-time` (0.1 s), aborted by new input via `while-no-input`. On interruption it
stores `(* delta (- 1 percentage))` as a window parameter; a new scroll in the same direction within
1.0 s does `(setq delta (+ delta rem))`. **Never drop unplayed distance, never play two envelopes at
once** — the residual idea expressed in a tween.

**(b) A real velocity estimator** — a 30-entry ring of `(timestamp . delta)`:

```elisp
(* (/ total (- (float-time) (caar (last elts))))
   pixel-scroll-precision-initial-velocity-factor)     ; factor = 0.0335/4
```

reset on direction change or a >0.5 s gap.

**(c) Momentum as a separate output stage.** `pixel-scroll-start-momentum` (bound to `<touch-end>`)
linearly decays that velocity over `momentum-seconds = 1.75` in `momentum-tick = 0.01` steps, gated by
`min-velocity = 10.0`. Off by default.

Also note the policy split `pixel-scroll-precision-interpolate-mice` (default `t`): Emacs *interpolates*
discrete wheel clicks but scrolls trackpad pixel deltas directly. *Skeptical note:* the loop is a
`sleep-for` busy loop, not a display-link callback — take the structure, not the scheduling.

### 3.4 Zed — no animation at all

[`crates/editor/src/scroll.rs`](https://github.com/zed-industries/zed/blob/main/crates/editor/src/scroll.rs):
`pub type ScrollOffset = f64;` and `ScrollAnchor { offset: Point<ScrollOffset> /* in LINES */, anchor: Anchor }`.
In `element/mouse.rs` the wheel goes straight in:
`new_lines = current_lines − (delta_px × sensitivity) / line_height`, committed on the event. Rows are
placed at `line_height * (display_row.as_f64() − scroll_position.y)`; **x is pixel-snapped, y is not.**
Grep of `scroll.rs`/`autoscroll.rs` finds no tween, timer, or easing. GPUI reads macOS `phase()` but
**never `momentumPhase`**, so inertia events arrive as ordinary `Moved` deltas — macOS supplies the
physics. Its one input filter is an axis lock (`SCROLL_EVENT_SEPARATION = 28 ms`, unlock at `px(6.)`
and 1.9×), not a smoother. The `ScrollAnchor` design — position as *(text anchor, fractional line
offset)* — is the same instinct as "content must not affect motion."

### 3.5 Terminals

**kitty** reversed its 2018 refusal ([#1123](https://github.com/kovidgoyal/kitty/issues/1123): *"way
too much work"*) and merged [PR #9330](https://github.com/kovidgoyal/kitty/pull/9330) for 0.46,
shipping `pixel_scroll` **on by default**. State is `(scrolled_by: int rows, pixel_scroll_offset_y: px)`;
`screen.c` recomputes `floor(total / cell_height)` plus remainder, and `shaders.c` renders **one extra
row** and shifts the origin — no timer, no easing:

```c
const unsigned int render_offset = pixel_scroll_enabled(screen) ? 1u : 0u;
row_offset_for_screen(): return -1.f + (float)(screen->pixel_scroll_offset_y / (double)screen->cell_size.height);
```

kitty animates exactly one thing: *keyboard* `scroll_line_up/down` (0.49) — **linear** interpolation
over the keyboard-repeat interval at 1/60, using absolute positioning "to avoid pixel rounding errors
from incremental fractional scrolls", and `finish_scroll_animation()` snaps to the integer target the
moment a mouse event arrives. **Animations never queue.** Where the OS gives no inertia (Wayland),
`glfw/momentum-scroll.c` synthesizes it: `friction = 0.96` per 10 ms, velocity over a 150 ms window;
*"On macOS, the native OS based momentum scrolling is used."*

**WezTerm** refuses ([#382](https://github.com/wezterm/wezterm/issues/382): *"wezterm doesn't and won't
support per-pixel scrolling"*; [#3812](https://github.com/wezterm/wezterm/issues/3812): *"you'd need to
dynamically switch to partially showing rows from either the top or bottom"*), but its macOS accumulator
is worth copying (`window/src/os/macos/window.rs`): carry the fractional remainder, **zero it on
direction change**, and **zero it plus round-away-from-zero after a 250 ms staleness gap**. wez:
*"Without the accumulator… the movement would feel very janky."*

**Alacritty** — [#2053](https://github.com/alacritty/alacritty/issues/2053) open since 2019, `P - low`.
The OP's framing is the sharpest statement of why terminals differ: *"A new line of text in a terminal
comes into existence at the moment it is displayed."* chrisduerr rejects animating *incoming* lines but
concedes animating viewport motion is *"not completely impossible."*

**Ghostty** — nothing shipped; [discussion #2355](https://github.com/ghostty-org/ghostty/discussions/2355)
is mitchellh's *"Thinking about it."* (**thin**). #3206 proposes kitty's mechanism and flags a live bug
in `Surface.zig`: `amount` is not truncated before `pending_scroll_y = poff - (amount * cell_size)`,
making it algebraically zero and discarding the sub-cell remainder.

**Sublime Text — thin, do not build on it.** No source, no changelog. Only `scroll_speed` (*"Set to 0 to
disable smooth scrolling"*, [docs](https://docs.sublimetext.io/reference/settings.html)) and a global
`animation_enabled`. The naming *implies* a rate-scaled tween, but that is inference from setting
semantics.

---

## 4. Motion theory

### 4.1 Minimum jerk (Flash & Hogan 1985) — and where it fails here

*"The coordination of arm movements: an experimentally confirmed mathematical model,"* J. Neuroscience
5(7):1688–1703 ([jneurosci.org/content/5/7/1688](https://www.jneurosci.org/content/5/7/1688); PDF 403s,
so the normalized form is cited from [arXiv:2102.07459](https://arxiv.org/pdf/2102.07459)). Minimize
`J = ∫₀ᵀ (d³x/dt³)² dt`; with τ = t/T the minimizer is

  **x(τ) = x₀ + Δx·(10τ³ − 15τ⁴ + 6τ⁵)**

pinned by six boundary conditions: **x(0)=x₀, ẋ(0)=0, ẍ(0)=0, x(T)=x_f, ẋ(T)=0, ẍ(T)=0.**

It is a *point-to-point, fixed-duration, rest-to-rest* trajectory — optimal exactly when nothing else
is happening. Three consequences:

1. **Zero terminal velocity is baked in.** Every envelope brakes to a full stop the user did not ask
   for. At one row per envelope this *is* the reported isolated 0→peak→0 pulse. **[slow] [tick]**
2. **Zero initial velocity is baked in.** Starting from rest while the surface is already moving is a
   velocity discontinuity.
3. **Fixed T cannot serve a target that arrives at t = 0.4T.**

**Superposition — and the precise threshold.** Flash & Henis (1991), *"Arm trajectory modification
during reaching towards visual targets,"* J. Cognitive Neuroscience 3(3):220–230 (full text:
http://e.guigon.free.fr/rsc/article/FlashHenis91.pdf) models target-jump corrections as a min-jerk
submovement *"vectorially added"* to the ongoing one — the same construction as summing per-row
envelopes. Their Eq. (2) leaves the coefficients free and fits them; the model's validation is that
they come out minimum-jerk:

> "the calculated mean values of the three coefficients of the polynomials describing the added
> trajectory units were found to be a₃ = 9.85 ± 1.51, a₄ = −14.64 ± 3.44, and a₅ = 5.90 ± 1.50
> (N = 64). The hypothesis that these mean values are equal to those of the corresponding minimum-jerk
> coefficients for a control movement (a₃ = 10.0, a₄ = −15.0, a₅ = 6.0) was accepted…"

The explicit `X(t) = X₁(t) + X₂(t)` form is in the NIPS companion (Henis & Flash 1991,
[proceedings.neurips.cc](https://proceedings.neurips.cc/paper_files/paper/1991/file/7d04bbbe5494ae9d2f5a76aa1c00fa2f-Paper.pdf),
Eqs. 2–4).

**Correcting a tempting over-claim:** summing min-jerk envelopes is *not* inherently bumpy. Flash &
Henis's own Figure 1 shows the same-direction double-step at ISI = 100 ms as a **single, broad, skewed
peak** — not two peaks — and the paper never uses "double-peaked." (Their mean onset delays of
130/180/230 ms against a 522 ms first-unit duration give d/T = 0.25–0.44.) The honest statement is a
**threshold**:

> For two same-direction min-jerk bells of duration T offset by onset delay d, the sum stays
> **single-peaked iff d ≤ T/2**, for any amplitude ratio. (At τ = ½ the first bell's acceleration
> changes sign; if nothing has been added by then, a local maximum is forced there.) For
> 0.5 < d/T < 1/√3 ≈ 0.577 there is a three-peak ripple band; the clean two-peak shape appears at
> d = T/√3, where `s''(centre) = (−60 + 180d²)/T³ = 0`.

But staying under the threshold is not free. Peak-velocity amplification for two equal-amplitude bells:

| d/T | 0 | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 | ≥0.577 |
|---|---|---|---|---|---|---|---|
| peak(sum)/peak(one) | **2.00** | 1.96 | 1.84 | 1.66 | 1.41 | 1.13 | 1.00 |

**This is the sharp diagnosis of the current scheme: it fails in both directions.** With arrivals
spaced further apart than T/2 (slow ticks, a laggy link) you get bumps; with arrivals closer than T/2
(a fast flick, an SSH burst) you stay unimodal but overshoot by up to 2× per overlapping pair,
compounding across a burst. Summation cannot avoid both. **[slow] [tick] [fast] [ramp]**

⚠️ The threshold, the 1/√3 boundary and the amplification table are **derivations**, not results quoted
from the literature — verify them before relying on the exact numbers. Corroborating primary sources
for the *superposition* claim itself: Milner 1992, Neuroscience 49(2):487–496 (*"the submovements
superimpose linearly to produce the composite movement"*); Novak, Miller & Houk 2002, Exp Brain Res
144:351–364 (overlapping submovements *"may account for the previously observed, speed-dependent
asymmetry of the velocity profile"* — i.e. overlap shows up as **skew**, matching the threshold); and
Dickey, Amit & Hatsopoulos 2013, Front. Neural Circuits 7:51, which states the bumpy case outright:
*"If the target jump happens soon after movement onset, the correction will be triggered before the
original movement ends. This means that the velocity profile will be double-peaked, and it will not
return to 0 between the peaks."*

**The open-loop critique, stated in the HCI domain.** Fischer, Klar, Fleig, Grüne & Müller, *"Optimal
Feedback Control for Modeling Human–Computer Interaction,"* ACM TOCHI 29(6), 2022
([arXiv:2110.00443](https://arxiv.org/pdf/2110.00443)) — a paper about *mouse pointing*, so the closest
domain to this one. On min-jerk:

> "…assumes that the objective of users is to generate smooth movements by minimizing the jerk of the
> end-effector … **while reaching the target exactly at a prescribed movement time with zero final
> velocity and acceleration**."

> "**as an open-loop model, the movement trajectory is completely specified at the beginning of the
> movement, and in its standard form, the model cannot react to perturbations** … models based on
> optimal feedback control are required."

And directly on the sum-of-submovements workaround:

> "A tempting approach to resolve this issue is an **iterative-submovement version of MinJerk** … At
> its core, however, it requires the manual definition of when a submovement starts and terminates.
> Even more critically, the kinematic properties of the end-effector … need to be known at the
> beginning and at the end of each path segment."

Their Eq. 10a/10b gives the 6×6 coefficient matrix for the nonzero-boundary quintic
(p₀,v₀,a₀) → (p_f,v_f,a_f), if you want that variant rather than a spring.

*Skeptical note:* the nonzero-boundary quintic above is a legitimate retargeting primitive (Fischer
et al. Eq. 10; also Ghazaei Ardakani et al., *Online Minimum-Jerk Trajectory Generation*). But once you
are recomputing coefficients from live `(position, velocity, acceleration)` on every event, you have
built a worse-conditioned spring. Note also that Henis & Flash 1995 (Biol Cybern 72:407–419) preferred
superposition over **abort-and-replan** — which is exactly the nonzero-boundary quintic — on grounds of
*biological plausibility* ("no efference copy required"), not motion quality. That argument does not
transfer to a scroll animator, which has its own exact state for free.

### 4.2 The critically damped spring — the standard velocity-continuous follower

Ryan Juckett, *"Damped Springs"* ([ryanjuckett.com/damped-springs](https://www.ryanjuckett.com/damped-springs/)):
`a + 2ζω·v + ω²·x = 0`, ω = √(k/m), ζ = β/(2√(mk)); at ζ = 1,

  x(t) = ((v₀ + x₀ω)·t + x₀)·e^(−ωt)   v(t) = (v₀ − (v₀ + x₀ω)·ω·t)·e^(−ωt)

— identical to Neovide's `update()` (`a = x₀`, `b = x₀ω + v₀`, `c = e^(−ω·dt)`). Juckett's argument for
the analytic form with precomputed coefficients (`newPos = posPosCoef·oldPos + posVelCoef·oldVel`) is
stability at arbitrary `dt`.

Why it is the right primitive: **state is (position, velocity); a retarget changes only the force
term.** Velocity is never touched, so C¹ continuity is free for any number of retargets at any point in
the motion. There is no "current animation" to interrupt, because there is no animation object — only
state and a target. Cost: asymptotic convergence, so you need an explicit settle threshold.

### 4.3 SmoothDamp — the same thing plus a speed clamp

Unity's published `Runtime/Export/Math/Mathf.cs` (verbatim below; its own comment reads
`// Based on Game Programming Gems 4 Chapter 1.10` — Thomas Lowe, *"Critically Damped Ease-In/Ease-Out
Smoothing"*). Docs: [Mathf.SmoothDamp](https://docs.unity3d.com/ScriptReference/Mathf.SmoothDamp.html).

```csharp
float omega = 2F / smoothTime;
float x = omega * deltaTime;
float exp = 1F / (1F + x + 0.48F*x*x + 0.235F*x*x*x);      // Padé approx. of e^(-x)
float change = Mathf.Clamp(current - target, -maxSpeed*smoothTime, maxSpeed*smoothTime);
target = current - change;
float temp = (currentVelocity + omega * change) * deltaTime;
currentVelocity = (currentVelocity - omega * temp) * exp;
float output = target + (change + temp) * exp;
if (originalTo - current > 0.0F == output > originalTo) {   // prevent overshoot
    output = originalTo;  currentVelocity = (output - originalTo) / deltaTime;
}
```

Two features Neovide lacks and this app wants: a **`maxSpeed` clamp applied to the error**
(`maxChange = maxSpeed * smoothTime`) — the natural place to bound a fast flick — and an explicit
overshoot guard. Note `omega = 2/smoothTime` here vs Neovide's `4/animation_length`: same knob, 2×
different calibration, so don't port tuned constants between them.

### 4.4 Separate input-velocity estimation from output animation

The missing stage: estimate a filtered input velocity, then drive a *camera* that integrates it.

- **EMA baseline:** `v ← v + α(v_inst − v)`, `α = 1 − e^(−dt/τ)`. Fixed lag/smoothness tradeoff.
- **1€ filter** (Casiez, Roussel & Vogel, CHI 2012, [gery.casiez.net/1euro](https://gery.casiez.net/1euro/))
  removes that tradeoff with a velocity-adaptive cutoff:

    f_c = f_cmin + β·|ẋ|,  α = 1/(1 + τ/T_e),  τ = 1/(2π f_c),  T_e = 1/rate

  with ẋ itself low-passed at `dcutoff`. The authors' tuning rule is a precise statement of the two
  complaints and the knob between them: *"if high speed lag is a problem, increase beta; if slow speed
  jitter is a problem, decrease fcmin."* **[slow] [ramp]**
- **Emacs' ring estimator** (§3.3) is the practical event-driven form, and its resets on direction
  change / staleness are what stop stale velocity leaking across gestures.

The framing that unifies §1–§3: a camera has *one* position and *one* velocity and follows a target.
Every design here that feels good — Neovide's residual spring, Chromium's velocity-preserving retarget,
Zed's direct fractional offset — is a camera. Every design that jitters is a queue.

### 4.5 Quantized targets: quantize the model, not the motion

- Keep the rendered position a real number of rows and render at fractional row offsets (kitty's extra
  row + `−1.f + offset/cell_height`; Zed's `line_height * (row − scroll_position.y)`; Neovide's floor +
  fractional translate). The row grid samples content; it does not constrain where the viewport sits.
- Snap only on settle, far below perceptual threshold (Neovide: 0.01 rows). Never round mid-motion.
- Watch pixel rounding too: Neovide's `scroll_offset_pixels.round()` is a 0.5 pt quantum on 2× Retina
  and is a plausible contributor to residual slow-speed jitter (neovide#3332). Zed pixel-snaps x but
  deliberately **not** y.
- On input, carry the sub-row remainder, and follow WezTerm: zero on direction change, zero + round
  away from zero after a staleness gap.

---

## 5. Animating against a laggy authoritative source

### 5.1 Valve entity interpolation — render a fixed interval *behind* the newest state

*Source Multiplayer Networking*, Valve Developer Community
([wiki](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking); it is behind bot
protection, so quotes are from a verbatim mirror,
[gist](https://gist.github.com/CoolOppo/fe0586836de3fb2f90f9)); derived from Yahn Bernier's
*Latency Compensating Methods in Client/Server In-game Protocol Design and Optimization* (GDC 2001).

> "Source defaults to an interpolation period ('lerp') of 100-milliseconds (`cl_interp 0.1`); this way,
> **even if one snapshot is lost, there are always two valid snapshots to interpolate between**."

> "the client render time is shifted back by 50 milliseconds, entities can be always interpolated
> between the last received snapshot and the snapshot before that."

> "Entity interpolation causes a constant view 'lag' of 100 milliseconds by default… even if you're
> playing on a listenserver."

> "the renderer uses extrapolation (`cl_extrapolate 1`)… done only for 0.25 seconds of packet loss
> (`cl_extrapolate_amount`), since the prediction errors would become too big after that."

The sizing rule: the delay is **twice the update interval** (100 ms at 20 Hz), expressed historically as
`cl_interp_ratio / cl_updaterate` — in *arrival intervals*, not milliseconds.

**Mapping.** Let `T̄` estimate the interval between row arrivals from nvim. Keep a queue of
`(arrival_time, cumulative_row_position)` and render at `now − k·T̄`, `k ≈ 1.5–2`, interpolating between
the two bracketing samples. A burst of five arrivals becomes five queue entries walked at the expected
pace instead of five overlapping envelopes; a gap doesn't starve the animator. The knob is `k` in units
of arrival interval, costing exactly `k·T̄` of visual latency — invisible locally, and the honest price
over SSH. This is the principled form of the current latency-adaptive 180→480 ms envelope: a **delay
budget**, not a duration, which is why one mechanism handles both bursts and gaps. Cap extrapolation
(Valve: 0.25 s) — rows you never received cannot be drawn anyway. **[fast] [ramp]**

### 5.2 Prediction with reconciliation — the other half

Same article: *"the local client just predicts the results of its own user commands."* Modern write-up:
Gabriel Gambetta, [Fast-Paced Multiplayer](https://www.gabrielgambetta.com/client-server-game-architecture.html)
I–III — predict locally, buffer unacknowledged inputs, re-apply those the server hasn't seen.

**Mapping.** On a wheel event, move the *rendered* position immediately by the rows you are about to
request; keep a requested-but-unacknowledged count; when `win_viewport` confirms `scroll_delta = N`,
decrement. Any discrepancy (end-of-buffer clamp, a fold, `mousescroll` scaling) becomes a small residual
fed to the same animator rather than a jump. The existing "velocity-hold while wheel input is
unanswered" is prediction *without* reconciliation; adding the correction term is what makes
end-of-buffer stop cleanly instead of overshooting and snapping back.

Note the tension with §5.1: prediction removes latency, interpolation delay adds it. Games run both
because they apply to different things. The scroll analogue: **predict from the local wheel, interpolate
the correction stream from nvim. Do not interpolate your own input.**

---

## 6. Ranked: most likely to fix the complaints

**1. One residual critically damped spring, replacing the sum of envelopes.** *(Neovide
`animation_utils.rs` + `flush()`; Juckett; Lowe/GPG4.)* State `(residual_rows, velocity)`; each arrival
does `residual −= scroll_delta` and leaves velocity alone; analytic step, ω = 4/L, settle at 0.01 rows.
Removes the concept of "an envelope," so nothing can start from rest or brake mid-gesture. fredizzimo
shipped this for precisely *"constantly speeding up and slowing down."* Per §4.1, summation fails in
*both* directions — bumps when arrivals are spaced wider than T/2, up to 2× overshoot per overlapping
pair when they are closer — so no choice of envelope duration escapes it. **[slow] [tick] [fast]
[ramp]** — highest confidence, smallest diff.

**2. Drive motion from `win_viewport.scroll_delta`, never `grid_scroll`.** *(nvim `ui.txt`;
`ui_ext_win_viewport`; neovim#19227 → PR #19270.)* `grid_scroll` is documented as *"semantically
unrelated to editor scrolling"* and isn't emitted at all past one screen. `scroll_delta` is an integer
screen-row count already correct across folds, wrap, `skipcol`, and diff filler. **[content]**

**3. Keep the incoming grid separate from the displayed grid; commit on `win_viewport`.** *(ui.txt
verbatim; neovim#23609; neovide#2278.)* Otherwise you get one frame of new-offset-with-old-content —
measured at *"perhaps every 10th scroll event"* with folds. Requires nvim ≥ 0.9.2. Heed fredizzimo's
warning: **smoother rendering makes this bug more visible, not less**, so fixing #1 first will surface
it. **[content]**

**4. Estimate input velocity, and render a fixed interval behind the newest arrival.** *(Valve
`cl_interp`; Emacs ring estimator; 1€ filter.)* (a) a 20–30 sample `(t, delta)` ring with resets on
direction change and staleness; (b) render at `now − k·T̄`, `k ≈ 1.5–2`. Valve sizes the delay at twice
the update interval so a lost update never starves the interpolator. Replaces the latency-adaptive
duration with a delay budget. **[fast] [ramp]** — the item that specifically targets SSH burstiness.

**5. Fix the input gain: reconcile the accumulator with `'mousescroll'`.** *(nvim `options.txt`
default `ver:3`; Neovide `mouse_manager.rs`; WezTerm's accumulator.)* Either set `mousescroll=ver:1` or
divide by the count — a "1-row tick" that moves 3 rows feels chunky no matter how good the animator is.
Add WezTerm's two rules (zero on direction change; zero + round-away-from-zero after ~250 ms). Cheapest
item here. **[tick]**

**6. Cap far scrolls: animate a fixed short distance, not the real one.** *(Neovide
`scroll_animation_far_lines`, default 1.)* Jump to within N rows, blank the vacated rows, animate only
those. nvim's own `scroll_delta` is *"an approximate value"* past one screen. Also decide deliberately
between Neovide's residual clamp and a SmoothDamp-style `maxSpeed` bound. **[fast]**

**7. Consider dropping animation for gestures: fractional-row rendering straight from the wheel.**
*(Zed `ScrollOffset = f64` + `ScrollAnchor`; kitty 0.46 `pixel_scroll`.)* Where both the newest terminal
and the newest editor independently landed. Nothing to interpolate, so nothing can jitter — **[slow]
[tick] [fast] [ramp]** all vanish for trackpad input. The catch: nvim owns *which rows exist*, so the
fractional position can only run ahead within the retained filmstrip, making this the prediction half of
#4. Highest ceiling, highest cost, only item that changes architecture. kitty's policy boundary is the
right one: **animate discrete commands (`<C-e>`, `<C-d>`), never animate a gesture.**

**8. If you keep a tween: retarget preserving velocity, clamp duration by distance/velocity.**
*(Chromium `UpdateTarget`; VS Code's `reuseAnimation`.)* Sample position *and* velocity, build one curve
from that position with matching initial slope (`new_slope = velocity · new_duration / new_delta`, via
the Bézier's first control point), duration `min(constant, 2.5 · distance/velocity)`. Chromium's comment
names the symptom: *"minimizes the 'rubber-band' bouncing effect when |velocity| is large and
|new_delta| is small."* **[ramp] [slow]** Strictly better than VS Code's `combine()`.

### Two non-animation items that will otherwise be blamed on the animation

- **macOS frame pacing.** neovide#3237: *"When the vblank is missed, a swap is allowed immediately, and
  the following frame is also animated immediately because we are late."* Fix named as
  `CAMetalDisplayLink`. Plus PR #2188: animate early in the frame, and **keep ticking on dropped frames**
  rather than integrating one huge `dt` after.
- **Round-trip serialization.** neovide#2770: requests instead of notifications means each wheel step
  waits for the previous response, and `nvim_input_mouse` is one RPC per step. Over SSH a flick is tens
  of serialized round trips. **No animation change fixes this** — verify it first.

### Source quality

- **Read directly:** Neovide `animation_utils.rs`/`rendered_window.rs`/`mouse_manager.rs`; nvim `ui.txt`,
  `options.txt`, `window.c`; VS Code `scrollable.ts`; Chromium `scroll_offset_animation_curve.cc`; Emacs
  `pixel-scroll.el`; kitty `screen.c`/`shaders.c`/`window.py`; Zed `scroll.rs`/`element.rs`/
  `gpui_macos/events.rs`.
- **Maintainer statements in threads:** neovide #1790, #1334, #2797, #2770, #3237; neovim #19227, #23609;
  wezterm #382/#3812; alacritty #2053; kitty #1123/#4694.
- **Thin — don't build on:** Sublime Text (settings names only); Ghostty smooth scrolling (*"Thinking
  about it."* is the entire record); neovide#3332 (no maintainer reply, though corroborated by source);
  neovide#1836 (substance is all in linked PRs).
- **Verified against downloaded primaries:** Unity `Mathf.cs` (SmoothDamp body and its
  "Game Programming Gems 4 Chapter 1.10" attribution); Flash & Henis 1991 full text (the fitted
  coefficients a₃/a₄/a₅, "vectorially added", and Figure 1 showing the same-direction case as a single
  *skewed* peak — the paper never says "double-peaked"); Fischer et al. TOCHI 2022 (all three quotes).
- **Derivations, not literature — verify before relying on the numbers:** the d ≤ T/2 unimodality
  threshold, the 1/√3 ripple boundary, and the peak-amplification table in §4.1. They were reached
  independently twice and are consistent with Flash & Henis's own data (d/T = 0.25–0.44, single skewed
  peaks), but no source states them.
- **Not from a primary source:** the Valve wiki is bot-blocked (verbatim gist mirror used); the Flash &
  Hogan 1985 PDF 403s, so the normalized polynomial is cited from arXiv:2102.07459 rather than the
  paper. Todorov & Jordan 2002 and Hoff & Arbib 1993 could not be reached at all and are not cited.
