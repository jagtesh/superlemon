*Research pass, 2026-08-29, sources read directly; see scroll-camera.md for the synthesis.*

# How production systems make scrolling smooth across the speed range

Sourced brief. Every formula below was read out of primary source (repo raw files, Apple doc JSON, author reference implementations) unless explicitly flagged as unconfirmed.

**The single structural finding.** Not one shipping system models scroll motion as *a sum of fixed-duration envelopes added per input event*. Every one of them keeps **one** animation object holding `(position, velocity)` and **retargets** it: the incoming event moves the *target*, and the animator continues from its current position **and current velocity**. Chromium and Firefox both literally accumulate into the target (`new_target = old_target + delta`) rather than starting a new curve. Superposition of independent pulses is the thing everybody avoided, because it is exactly what produces an isolated 0→peak→0 bump per arrival at low rates and an incoherent stack at high rates.

---

## 1. Chromium — `cc/animation/scroll_offset_animation_curve.cc`

<https://chromium.googlesource.com/chromium/src/+/refs/heads/main/cc/animation/scroll_offset_animation_curve.cc>
The compositor-thread curve behind wheel/keyboard/programmatic animated scrolling.

**Duration.** Wheel scrolling uses `DurationBehavior::kInverseDelta` (`scroll_offset_animation_curve_factory.cc`: kMouseWheel→kInverseDelta, kKeyboard→kConstant, kProgrammatic→kDeltaBased). Constants, verbatim:

```cpp
const double kConstantDuration = 9.0;          // in "frames"
const double kDurationDivisor = 60.0;          // frames -> seconds
const double kInverseDeltaRampStartPx = 120.0;
const double kInverseDeltaRampEndPx   = 480.0;
const double kInverseDeltaMinDuration = 6.0;   // 100 ms
const double kInverseDeltaMaxDuration = 12.0;  // 200 ms
const double kInverseDeltaSlope  = (kInverseDeltaMinDuration - kInverseDeltaMaxDuration)
                                 / (kInverseDeltaRampEndPx - kInverseDeltaRampStartPx);
const double kInverseDeltaOffset = kInverseDeltaMaxDuration - kInverseDeltaRampStartPx * kInverseDeltaSlope;
```
```cpp
case DurationBehavior::kInverseDelta:
  duration = kInverseDeltaOffset + std::abs(MaximumDimension(delta)) * kInverseDeltaSlope;
  duration = std::clamp(duration, kInverseDeltaMinDuration, kInverseDeltaMaxDuration);
duration /= kDurationDivisor;
```
So: **the bigger the pending delta, the *shorter* the animation** — 200 ms at ≤120 px of pending distance, ramping linearly to 100 ms at ≥480 px. Fast scrolling gets snappier, not longer. Your current rule (stretch 180→480 ms when arrivals are bursty) is the exact inverse of Chromium's.

**Retargeting math** (`UpdateTarget`, verbatim core):

```cpp
gfx::PointF current_position = GetValue(t);
gfx::Vector2dF new_delta = new_target - current_position;
const base::TimeDelta new_duration = EaseInOutBoundedSegmentDuration(new_delta, t, delayed_by);
// Adjust the slope of the new animation in order to preserve the velocity of the old animation.
double velocity = CalculateVelocity(t);
double new_slope = velocity * (new_duration.InSecondsF() / MaximumDimension(new_delta));
timing_function_ = GetEasingFunction(new_slope);
initial_value_ = current_position;
target_value_  = new_target;
total_animation_duration_ = t + new_duration;
last_retarget_ = t;
```
`new_slope` is the old velocity expressed in *normalized* curve units (px/s × s / px). It is then baked into the Bézier by scaling the first control point's y:

```cpp
slope = std::clamp(slope, -1000.0, 1000.0);
return CubicBezierTimingFunction::Create(cp.x1, cp.x1 * slope, cp.x2, cp.y2);  // ease-in-out is (.42,0,.58,1)
```
i.e. the ease-in-out `(0.42, 0, 0.58, 1)` becomes `(0.42, 0.42·slope, 0.58, 1)`. A `slope` of 1 is exactly constant-velocity entry. And velocity is used to *cap* the duration, so a big velocity + small remaining delta can't rubber-band:

```cpp
double bound = (new_delta_max_dimension / velocity) * 2.5f;   // "fudge factor to account for the ease out"
return bound < 0 ? base::TimeDelta::Max() : base::Seconds(bound);
// then: min(EaseInOutSegmentDuration(...), VelocityBasedDurationBound(...))
```
Also note `scroll_offset_animations_impl.cc`: `gfx::PointF new_target = curve->target_value() + scroll_delta;` — deltas accumulate into the *existing* target. And there is a guard against retargeting to the same place (which would *lengthen* an inverse-delta animation).

**Fling.** `ui/events/gestures/fling_curve.cc` is a closed-form curve, not a spring:
`x(t) = α·e^(−γt) − β·t − α`, `v(t) = −αγ·e^(−γt) − β`, with `α = −5707.62`, `β = 172.0`, `γ = 3.7`. It seeds `time_offset_ = GetTimeAtVelocity(v0)` — i.e. it *enters the curve at the point matching your measured velocity*, rather than restarting. `ui/events/blink/fling_booster.cc` accumulates a second fling into the first (`velocity += previous_fling_starting_velocity_`) if it arrives within `kFlingBoostTimeoutDelay = 50 ms`, is same-direction (dot product > 0), and both exceed 350 px/s.

**Input resampling** — `ui/base/prediction/linear_resampling.cc`. Chromium does not consume raw event timestamps; it resamples the last two events to frame time: `sample_time = frame_time + kResampleLatency (−5 ms)`, clamped to `min(kResampleMaxPrediction = 8 ms, events_dt_/2)` past the last event, then linear lerp/extrapolate.

*Mapping.* Take three things: (a) accumulate row deltas into a target instead of adding envelopes; (b) invert the duration rule — shorter, not longer, when input is dense; (c) the velocity-bound `2.5·Δ/v` guard, which is the cheapest fix for flick overshoot.

## 2. Firefox — MSD physics (the closest match to your problem)

`layout/generic/ScrollAnimationMSDPhysics.cpp`, `gfx/layers/AxisPhysicsMSDModel.cpp`, `gfx/layers/AxisPhysicsModel.cpp` (all at `hg.mozilla.org/mozilla-central/raw-file/tip/...`).

**The model.** Unit mass, spring to destination, damping expressed via a damping *ratio*:
```cpp
double spring_force = (mDestination - aState.p) * mSpringConstant;
double damp_force   = -aState.v * mDampingRatio * mSpringConstantSqrtXTwo;  // = 2·sqrt(k)
return spring_force + damp_force;
```
So `a = k(d − x) − 2ζ√k·v`, i.e. `ω = √k`, and `ζ = 1` is exact critical damping. Wheel scrolling uses `GetDampingRatio() → 1.0`.

**Fixed timestep + interpolation** — Firefox independently implements Fiedler's scheme:
```cpp
const double AxisPhysicsModel::kFixedTimestep = 1.0 / 120.0;  // 120hz
void Simulate(const TimeDuration& aDeltaTime) {
  for (mProgress += aDeltaTime.ToSeconds() / kFixedTimestep; mProgress > 1.0; mProgress -= 1.0)
    Integrate(kFixedTimestep);
}
double GetPosition() const { return LinearInterpolate(mPrevState.p, mNextState.p, mProgress); }
```
with RK4 inside `Integrate`. The header comment states the rationale outright: *"advanced forward in time with a fixed time step to ensure that it remains deterministic given variable framerates... 120hz in order to ensure that every frame in a common 60hz refresh rate display will have at least one physics simulation sample."*

**The event-rate state machine — this is the direct answer to your "ramps up/down" complaint.** `ComputeSpringConstant(aTime)` chooses stiffness per arrival:

```cpp
if (!mPreviousEventTime)                       return motionBeginSpringConstant;      // 1250
if (deltaMS >= continuousMotionMaxDeltaMS)     return motionBeginSpringConstant;      // 120 ms -> treat as a fresh gesture
if (previousDelta && deltaMS >= slowdownMinDeltaMS            // 12 ms
                  && deltaMS >= previousDelta.ToMilliseconds() * slowdownMinDeltaRatio)  // 1.3
      // "The rate of events has slowed ... enough that we think that the current scroll motion is
      //  coming to a stop. Use a stiffer spring in order to reach the destination more quickly."
                                               return slowdownSpringConstant;         // 2000
                                               return regularSpringConstant;          // 1000
```
Defaults confirmed from `modules/libpref/init/StaticPrefList.yaml`: `motionBeginSpringConstant 1250`, `regularSpringConstant 1000`, `slowdownSpringConstant 2000`, `slowdownMinDeltaMS 12`, `slowdownMinDeltaRatio 1.3f`, `continuousMotionMaxDeltaMS 120`, `msdPhysics.enabled @IS_NIGHTLY_BUILD@`. With ζ=1 these are settle-time knobs: `ω = √1000 ≈ 31.6 rad/s` regular (≈ 220 ms to 1%), `√2000 ≈ 44.7` when decelerating, `√1250 ≈ 35.4` on the first event. The whole mechanism is *three numbers switched on inter-arrival timing* — no velocity estimator at all.

`Update()` retargets with full continuity: `mStartPos = PositionAt(mStartTime)` and the caller (`ScrollContainerFrame.cpp` ~line 2594) supplies `currentVelocity` from `mAsyncScroll->VelocityAt(now)` or `mVelocityQueue.GetVelocity()` — velocity survives even a change of animation *type*. The one guard on that carried velocity (added for bug 1846935) is a hard overshoot clamp derived from the spring's own energy budget:

```cpp
static double ClampVelocityToMaximum(double aVelocity, double aInitialPosition,
                                     double aDestination, double aSpringConstant) {
  double velocityLimit = sqrt(aSpringConstant) * abs(aDestination - aInitialPosition);
  return std::clamp(aVelocity, -velocityLimit, velocityLimit);
}
// MOZ_ASSERT(aDampingRatio >= 1.0, "Damping ratio must be >= 1.0 to avoid oscillation")
```
i.e. `|v| ≤ ω·|remaining|`. Carrying velocity into a *small* remaining distance is precisely how a velocity-continuous retarget goes wrong, and this one line is the whole fix — it is Firefox's analogue of Chromium's `2.5·Δ/v` duration bound.

**The older Bézier path** (`ScrollAnimationBezierPhysics.cpp`) is instructive because it is closest to your current design and still does better:
```cpp
int32_t eventsDeltaMs = (aTime - mPrevEventTime[2]).ToMilliseconds() / 3;   // average of last 3 intervals
int32_t durationMS = std::clamp<int32_t>(eventsDeltaMs * mIntervalRatio, mMinMS, mMaxMS);
```
`general.smoothScroll.durationToIntervalRatio = 200` (percent), `mouseWheel.durationMinMS = 50`, `durationMaxMS = 200`. Comment: *"the animation's duration should be longer than scroll events intervals (or else the scroll will stop before the next event arrives — we're guessing the next interval by averaging recent intervals)."* Duration tracks measured cadence at 2×, clamped. Velocity is injected into the spline control point:
```cpp
double slope = aCurrentVelocity * (mDuration / oneSecond) / (aDestination - aCurrentPos);
double normalization = sqrt(1.0 + slope*slope);
aTimingFunction.Init(w/normalization, slope*w/normalization, 1 - stopDecelerationWeighting, 1);
```
with `currentVelocityWeighting = 0.25`, `stopDecelerationWeighting = 0.4`. Note the `sqrt(1+slope²)` normalization keeps the control point at fixed *arc* distance — cleaner than Chromium's raw clamp to ±1000. The header comment states the design intent that your envelope model is missing: the duration ratio is *"a global ratio which defines how longer is the animation's duration compared to the average recent events intervals"* — the animation is **deliberately made longer than the event interval so the next event lands mid-animation and retargets it**. Long duration is fine; superposition is not.

**Wheel transactions** (`gfx/layers/apz/src/InputBlockState.cpp`, `WheelBlockState`): all wheel events route to one APZC for the transaction's life; `MaybeTimeout()` ends it after `mousewheel.transaction.timeout = 1500 ms` of quiet; a mouse move only breaks it after `mousewheel.transaction.ignoremovedelay = 100 ms`; and `Update()` resets `mScrollSeriesCounter` whenever the inter-event gap exceeds `mousewheel.scroll_series_timeout = 80 ms`, stamping `mScrollSeriesNumber` on each event. That counter — not a velocity — is what drives line-mode wheel acceleration (`mousewheel.acceleration.start = -1`, off by default).

*Mapping.* This is the design to copy nearly wholesale: one critically damped spring per axis on a fixed 120 Hz substep with interpolated readout, target = accumulated row offset, stiffness selected by inter-arrival timing. It needs no velocity estimator, which matters because your arrivals are round-trip-delayed and a naive estimator would measure the *network*, not the finger.

## 3. WebKit / Apple

- `ScrollAnimationKinetic.cpp` (WebKit main): closed-form exponential, `decelFriction = 4`, `x(t) = x₀ + (v₀/k)(1−e^{−kt})`, `v(t) = v₀e^{−kt}`; stop when `|v| < 1` px/s or `<1` px moved in a frame. Initial velocity is a **mean over a 150 ms history window** (`scrollCaptureThreshold {150_ms}`), not a two-sample derivative. Same-direction re-flicks compound via `velocityAccumulationFloor 0.33 / Ceil 1.0 / Max 6.0`.
- `ScrollAnimationSmooth.cpp`: `animationSpeed = 1000 px/s`, `maxAnimationDuration = 200 ms`, cubic-Bézier EaseInOut, switching to **EaseOut on retarget** — and it carries position but **not velocity**. This is the one production path that does what you do, and it is visibly the weakest: a first-derivative discontinuity at every retarget, patched by making the resumed curve ease-out only. Do not copy it.
- Phase handling (`PlatformWheelEvent.h`): `enum class PlatformWheelEventPhase { None, Began, Stationary, Changed, Ended, Cancelled, MayBegin, WillBegin }`, and the two predicates that matter: `isEndOfNonMomentumScroll() { phase == Ended && momentumPhase == None }`, `isTransitioningToMomentumScroll() { phase == None && momentumPhase == Began }`. On the first, GTK/WPE starts the kinetic animation; on the second, macOS just consumes the OS-synthesized momentum deltas — **WebKit does not simulate momentum on macOS at all**, it wraps AppKit's `_NSScrollingMomentumCalculator`.
- `UIScrollView.decelerationRate`: **skeptical note.** Apple's live documentation (verified via `developer.apple.com/tutorials/data/.../decelerationrate-swift.struct/normal.json`) says only *"The default deceleration rate for a scroll view."* The values 0.998 / 0.99 are `extern const` in `UIScrollView.h` — not literals in any header or doc page. The closed form `x(t) = x₀ + v₀(rate^t − 1)/ln(rate)` is **not published anywhere primary**; it is the integral of `v(t) = v₀·rate^t` and agrees with the projection formula to 0.1% (`−1/ln 0.998 = 499.5` vs `0.998/(1−0.998) = 499`).
- WWDC 2018 §803 projection. The formula is real and appears verbatim in the presenter's companion sample (`nathangitter/fluid-interfaces`, `Rotation.swift`):
  ```swift
  func project(initialVelocity: CGFloat, decelerationRate: CGFloat) -> CGFloat {
      return (initialVelocity / 1000) * decelerationRate / (1 - decelerationRate)
  }
  ```
  **Units:** `initialVelocity` is pt/**second**; `/1000` converts to per-ms because `decelerationRate` is a per-millisecond retention factor. Transcript quotes worth keeping: *"we don't use the last position. We use the history of the touch, to ensure that all the motion is transferred fluidly"*; *"it's this imaginary, projected position that I then use as the nearest corner position. And, I send my PIP there, by retargeting it."* That is the pattern: **project → snap the projection to a legal discrete stop → retarget a spring there with the current velocity.** For a row-quantized backend that is almost the exact required algorithm.
- `CASpringAnimation.settlingDuration` (Apple doc JSON): *"The estimated duration required for the spring system to be considered at rest"* — a closed-form settle estimate available from the parameters, which is what you'd use to decide when to stop ticking.
- Unconfirmed: the rubber-band formula `(1 − 1/(d·c/dim + 1))·dim` with c=0.55 appears only in reverse-engineering blogs. Chromium's fork of the old `ScrollElasticityController` does carry `kRubberbandStiffness 20, kRubberbandAmplitude 0.31, kRubberbandPeriod 1.6` and `expf(−elapsed·stiffness/period)`.

## 4. Velocity estimation from bursty / discrete events

- **AOSP `VelocityTracker.cpp`.** The default is per-axis, and the choice is directly on point:
  ```cpp
  {AMOTION_EVENT_AXIS_X, LSQ2}, {AMOTION_EVENT_AXIS_Y, LSQ2}, {AMOTION_EVENT_AXIS_SCROLL, IMPULSE}
  static const std::set<int32_t> DIFFERENTIAL_AXES = {AMOTION_EVENT_AXIS_SCROLL};
  ```
  Android uses **IMPULSE for the scroll/wheel axis specifically because it is differential** (deltas, not positions) and low-rate. `HORIZON = 100ms`, `ASSUME_POINTER_STOPPED_TIME = 40ms`. The estimator:
  ```cpp
  vfinal = sqrt(2) * sqrt( Σ_i (v[i] − v[i−1])·|v[i]| ),  first term halved
  ```
  derived from the work–energy theorem (`dW = m·v·dv`); `|v[i]|` keeps the sign so deceleration counts as negative work. Java doc string: IMPULSE is *"VERY GOOD. Works with duplicate coordinates, unclean finger liftoff"* while LSQ2 *"can be confused... delayed, duplicate or jittery"*. No matrix solve, O(n), tolerant of duplicate/irregular samples — ideal for wheel ticks.
  *Skeptical note:* no accessible commit message or engineering writeup justifying impulse-over-LSQ was found; the quality strings and the derivation comment are the only first-party rationale.
- **Chromium** has *no* impulse strategy; `ui/events/velocity_tracker/velocity_tracker.cc` (moved from `gesture_detection/`) defaults to `LSQ2`, `kHorizonMS = 100`, `kHistorySize = 20`, `kAssumePointerMoveStoppedTimeMs = 40`.
- **Line-tick wheel mice — important negative result.** Neither browser estimates velocity from discrete ticks. Chromium groups them by an idle timer (`kDefaultMouseWheelLatchingTransaction = 500 ms`, `kWheelLatchingSlopRegion = 10.0`) into synthetic phase-begin/end; Firefox's `WheelTransaction` accelerates by a *tick counter*, not a velocity (`mousewheel.acceleration.start = -1`, i.e. **off by default**; `scroll_series_timeout = 80 ms`). The rate problem is solved at the device layer instead (`REL_WHEEL_HI_RES`, 120 units per detent). I found no primary analysis of velocity-estimation aliasing at low wheel rates — treat that as an open problem, and prefer Firefox's cadence-switching over a velocity estimate for tick input.
- **1€ filter** (Casiez/Roussel/Vogel, CHI 2012; equations from the authors' reference implementation at `github.com/casiez/OneEuroFilter` — the paper PDF is 404 on the author page):
  `α(fc) = 1/(1 + τ/Te)`, `τ = 1/(2π·fc)`, `Te` recomputed per sample from the actual timestamp gap; `fc = fcmin + β·|x̂̇|`; `dcutoff = 1.0 Hz`, `mincutoff = 1.0`, `beta = 0.0` defaults. Derivative is taken against the *previously filtered* value. Tuning rule, verbatim: *"If high speed lag is a problem, increase beta; if slow speed jitter is a problem, decrease fcmin."* Being natively irregular-rate, it is the right smoother for a bursty velocity signal.

## 5. Retargeting with continuity — the general form

- **Daniel Holden, "Spring-It-On"** <https://theorangeduck.com/page/spring-roll-call> — the exact closed-form critically damped step with initial velocity, timestep-independent:
  ```c
  float halflife_to_damping(float halflife) { return (4.0f * 0.69314718056f) / (halflife + eps); }
  void simple_spring_damper_exact(float& x, float& v, float x_goal, float halflife, float dt) {
      float y = halflife_to_damping(halflife) / 2.0f;
      float j0 = x - x_goal;
      float j1 = v + j0*y;
      float eydt = fast_negexp(y*dt);        // 1/(1 + x + 0.48x² + 0.235x³)
      x = eydt*(j0 + j1*dt) + x_goal;
      v = eydt*(v - j1*y*dt);
  }
  ```
  With a nonzero goal velocity, `c = g + d·q/((d·d)/4)` and `j0 = x − c`. Why exact beats Euler: *"lerping with a factor of 0.5 twice takes us 75% of the way toward the goal, while lerping with a factor of 1.0 once brings us 100%"* — semi-implicit Euler goes unstable once `damping·dt > 1`, the closed form is identical at any `dt`.
- **Unity `Mathf.SmoothDamp`** (`UnityCsReference/Runtime/Export/Math/Mathf.cs`), *"Based on Game Programming Gems 4 Chapter 1.10"* (Thomas Lowe, "Critically Damped Ease-In/Ease-Out Smoothing") — same solution with `omega = 2/smoothTime`, the `1/(1+x+0.48x²+0.235x³)` exp approximation, a **`maxSpeed` clamp** (`maxChange = maxSpeed * smoothTime`) and an explicit overshoot guard.
- **t3ssel8r second-order dynamics** — `y + k₁ẏ + k₂ÿ = x + k₃ẋ` with `k₁ = ζ/(πf)`, `k₂ = 1/(2πf)²`, `k₃ = rζ/(2πf)`. `f` is undamped natural frequency (Hz), `ζ` damping ratio, `r` the *input-derivative* response (r>0 anticipates target motion; r<0 winds up first). A public Godot port uses the unconditionally-stable semi-implicit form: `y += T·ẏ; ẏ = (k₂·ẏ + T·(x + k₃·ẋ − y)) / (k₂ + T·k₁)`. *Skeptical note:* the canonical source is a YouTube video and a paywalled Patreon post (403); the equations here come from a third-party port that credits it, so verify before shipping. The distinctive contribution is `k₃`: a target-velocity feed-forward term, which is exactly what lets a follower keep up with a ramping input instead of lagging it.
- Apple's `CASpringAnimation.initialVelocity` / `UISpringTimingParameters(...initialVelocity:)` exist for precisely this: *"Negative values represent the object moving away from the spring attachment point, positive values represent the object moving towards"* — the platform's own animation API assumes you hand it the velocity you were already carrying.

## 6. Frame pacing

- **Fiedler, "Fix Your Timestep!"** <https://gafferongames.com/post/fix_your_timestep/>: clamp `frameTime` to 0.25 s (spiral of death), accumulate, `while (accumulator >= dt) { previousState = currentState; integrate(currentState, t, dt); t += dt; accumulator -= dt; }`, render `currentState*α + previousState*(1−α)` with `α = accumulator/dt`. Firefox's `AxisPhysicsModel` is this algorithm verbatim at `dt = 1/120`.
- **Apple `CADisplayLink`**: `timestamp` is *"when the last frame displayed"*; the docs are blunt — *"If you need to calculate what to display next, use `targetTimestamp` instead."* `duration` is *"in an undefined state until the system calls the target's selector at least once"*; the real budget is `targetTimestamp − timestamp`. WWDC21 §10147 prescribes `progress += link.targetTimestamp − previousTargetTimestamp`, which self-corrects both ProMotion rate changes (120→60 Hz) and **skipped callbacks** (the delta simply comes back as ~16 ms instead of ~8 ms). `preferredFrameRateRange` picks a *factor* of the display max (120/60/40/30/24). On macOS 14+, `NSView.displayLink(target:selector:)` is the supported API; `CVDisplayLinkCreateWithCGDisplay` is deprecated in macOS 15.
- **Chromium** ticks animations off `BeginFrameArgs::frame_time` — *"the time at which the frame started. Used, for example, by animations to decide to slow down or skip ahead"* — never `TimeTicks::Now()` at callback entry. (Caveat: `BeginFrameArgs::MISSED` is *not* a dropped-frame signal; it means an observer registered mid-interval. `frames_throttled_since_last` is the drop counter.)

---

## Ranked: the 8 changes most likely to fix the stated complaints

1. **Replace the sum of envelopes with one stateful critically damped follower per axis** — state `(x, v)`, target = accumulated row offset in pixels. Every row arrival calls `SetDestination`, never `AddEnvelope`. This alone removes the isolated 0→peak→0 pulse at sub-row-per-frame rates and the incoherent stacking at high rates. *Firefox `AxisPhysicsMSDModel` (`a = k(d−x) − 2ζ√k·v`, ζ=1); closed form in Holden's `simple_spring_damper_exact`.*
2. **Accumulate deltas into the target rather than restarting a curve.** `new_target = target + delta`, clamped; position and velocity carry over untouched, subject to one guard — `|v| ≤ √k · |target − position|` — so carried velocity can't overshoot into a short remaining distance. *Chromium `ScrollOffsetAnimationImpl::ScrollAnimationUpdateTarget`; Firefox `Update()` with `mStartPos = PositionAt(mStartTime)` + caller-supplied `currentVelocity`, and `ClampVelocityToMaximum` (bug 1846935).*
3. **Switch stiffness on inter-arrival cadence, not on a velocity estimate.** Port Firefox's three-way rule directly: first event or gap ≥120 ms → soft-start `k≈1250`; gap ≥12 ms *and* ≥1.3× the previous gap → "coming to a stop", stiffen to `k≈2000`; otherwise `k≈1000`. This is precisely a ramp-down detector and needs nothing you don't already have. *Firefox `ComputeSpringConstant`, prefs from `StaticPrefList.yaml`.*
4. **Invert your duration rule: denser input → *faster* settling, not slower.** Chromium's wheel path ramps 200 ms → 100 ms as pending delta grows 120 → 480 px, and additionally caps duration at `2.5·Δ/v` so a big velocity into a small remaining delta cannot rubber-band. Your 180→480 ms stretch under burst is the source of the fast-flick mush. *Chromium `kInverseDelta*` + `VelocityBasedDurationBound`.*
5. **Use the macOS phase state machine you're currently ignoring.** `phase == .began` → soft-start stiffness and reset the follower's cadence history; `phase == .ended && momentumPhase == .none` → finger lifted, settle; `momentumPhase == .began/.changed` → the OS has *already* applied deceleration, so consume its deltas as target motion and do not add your own decay. *WebKit `isEndOfNonMomentumScroll` / `isTransitioningToMomentumScroll`; macOS momentum is `_NSScrollingMomentumCalculator`, not WebKit math.*
6. **Fixed-substep integration with interpolated readout, driven from `targetTimestamp`.** `dt = 1/120` (or 1/240), clamp the frame delta, `while (acc >= dt) integrate()`, render `lerp(prev, next, acc/dt)`. Advance by `link.targetTimestamp − previousTargetTimestamp` so ProMotion transitions and dropped callbacks self-correct. This kills residual jitter from variable `dt` at slow speeds, where a spring is most sensitive. *Fiedler; Firefox `AxisPhysicsModel::Simulate`; Apple WWDC21 §10147.*
7. **For flicks, project and retarget instead of chasing.** Estimate velocity, compute `projected = position + v_per_ms·rate/(1−rate)`, quantize that to a whole row, send *that many* rows to nvim, and retarget the spring at the quantized projection with the current velocity. This turns a long chain of round trips into one, which is the only real cure for round-trip-latency mush on fast flicks. *WWDC18 §803 `project()`; Chromium `FlingCurve` seeding `time_offset_ = GetTimeAtVelocity(v0)`.*
8. **If you do want a velocity signal (for #7 and for tick-cadence wheels), use the impulse estimator over a 100 ms horizon on the raw deltas, and smooth it with a 1€ filter.** Impulse is the AOSP default *for the differential scroll axis specifically*, is O(n), needs no matrix solve, and tolerates duplicate/irregular samples; the 1€ filter's `fc = fcmin + β|v̂|` gives you low-jitter at slow speeds and low-lag at fast speeds from one pair of knobs. Estimate from the **input event stream**, never from row arrivals — arrivals measure nvim's round trip, not the finger. *AOSP `ImpulseVelocityTrackerStrategy`; Casiez et al.*

**Honest caveats.** t3ssel8r's `k₃` feed-forward term is the most attractive idea here (it directly attacks lag during ramps) but its primary source is a video plus a paywalled post — validate before relying on it. Apple's 0.998/0.99 deceleration constants are folklore-by-consensus, not documented. And nobody has published a good answer for velocity from line-tick wheels; the shipping systems all dodge it with timeouts and counters, which is a reasonable thing for you to dodge it with too.
