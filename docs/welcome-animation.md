# Welcome hero v2: "the orb kicks the squircle into the Trash"

This follows the owner's revised storyboard. The orb is the actor and the squircle gets thrown away; the orb never goes into the Trash.

## Principles applied
- **Anticipation:** a twitch, a beat, a jiggle, then a crouch before the pop. A wind-up with a held tremble before the kick.
- **Squash and stretch:** squash and stretch preserve volume (3-D: the cross axis scales by 1/√s). The orb stretches along its velocity, which stands in for motion blur. Contacts squash with the contact point pinned, so nothing sinks or slides.
- **Physics:** hops are true ballistic arcs (g = 3000 pt/s², with 2300 pt/s² for the receding squircle). Horizontal drag lets a hop arrive steeply. Bounce heights decrease.
- **Springs:** glides use the SwiftUI `spring(duration:bounce:)` step response with bounce 0.12–0.18, i.e. ζ = 1 − bounce and ω = 2π/duration.
- **Follow-through:** damped jelly rings after every contact. The squircle tile recoils and dips when the orb leaves it and when it lands on it.
- **Light:** the glow is light the orb casts. On the squircle it falls off with the orb's distance from the socket. The orb carries a colourful shadow (its own colours, blurred and saturated):
  - While the orb is "out" toward you, the shadow sits behind it on the window, offset down and stretched.
  - In the final hover it is a flattened floor shadow that breathes with the bob.
- **Highlights stay world-fixed:** the orb is never rotated. Its "living" surface is a slow hue drift (`CIHueAdjust`), which leaves the white highlights alone.

## Timeline (Trash path, this Mac; seconds from start, auto-play 1.0 s after the window shows)
| t | beat |
|---|---|
| 0.00–0.72 | Wake. Twitch (5 Hz ring), still beat, jiggle (0.27–0.61), crouch (13 % squash, sinks into the socket, tile pressed 1–1.6 %). |
| 0.72 | **Pop.** Stretch up out of the socket (apex 34 pt). Grows to 1.06× (out toward you). The colourful shadow separates and the squircle's glow fades. The tile recoils (2.2 pt ring) and the glow blooms. |
| 1.03 | Falls back into the socket: one small bounce (13 % squash, 65 ms, rebounds 14 pt). |
| 1.20–1.70 | Glides up and away at 45° counter-clockwise (up-left when the Trash is to the right; mirrored otherwise). Spring 0.55 s, bounce 0.18. Holds there briefly. |
| 1.70–2.31 | Drops onto the top of the empty squircle. Lands with an 8–20 % squash, scaled by speed, then bounces 9 pt and 2.5 pt. The squircle dips on each landing. **Dock appears:** the real one is already visible; if not, a drawn Dock slides up with spring 0.55 s / 0.12. |
| 2.31–2.53 | Looks toward the Trash (leans 2.5 pt and 5 %). |
| 2.53–3.24 | Hops off the far side and catches itself in the air. Winds up: pulls back 16 pt with a 15 % squash, then a tremble at 19 Hz. |
| 3.24–3.31 | **Kick.** Rams the squircle (75 ms) and flattens against it (24 %, 60 ms). Recoils 18 pt and watches. |
| 3.33–4.38 | The squircle flies in a ballistic arc (apex ≤ 80 pt), making one full turn so it arrives upright. It shrinks to fit the bin (~0.39×). |
| 4.38 | Lands on the Trash's rim: 20 % squash, a glint ring from the lip, a 11 pt hop with a tip toward the bin. |
| 4.74 | Drops in behind the front lip (clipped). A stronger lip glint. The drawn Trash also gulps and shows as full. |
| 4.44–5.22 | The orb floats back along an arc to the icon's place (12 pt higher than the old orb centre). It shrinks back to 1.0× and its shadow morphs into the floor shadow. The glow (halo) returns. |
| 5.17 | `onHello`. "Hi, I'm Wisp" fades in and rises 7 pt over 1.1 s, under the orb. A VoiceOver announcement is also posted. |
| 6.32 | Hand-over to the window. The hover keeps going forever as Core Animation loops with the same phase: bob ±2.6 pt at 0.5 Hz, shadow scale/opacity, hue drift ±0.3 rad at 0.14 Hz. |

## Edge cases
- **Dock hidden, auto-hidden, full-screen Space, or on another display:** the window-list check (`dockIsShowing`) fails, or the Trash isn't on the window's screen. In that case a macOS-style Dock is drawn on the window's screen: system app icons, separator and Trash, on `NSGlassEffectView` (macOS 26+) or `NSVisualEffectView`. It slides up, receives the squircle and slides away.
- **Trash location:** Accessibility gives the item frame. The icon centre sits 1 pt above the item centre, and the lip is 0.24 tile above the icon centre (measured on this Mac). Without Accessibility, the position is estimated from Dock preferences (bottom Dock only).
- **Window on a secondary display:** everything plays on that display (tested on Sidecar).
- **Window moved mid-animation:** the orb follows the live window every frame; the squircle is independent once launched (tested).
- **Window moves to another display, or closes:** the run stops cleanly and goes to the final state, or tears down.
- **Not visible:** auto-play waits until the window is on the active Space and not occluded.
- **Replay on click or AXPress:** the squircle comes back, the orb settles into it, and the show replays (tested).
- **Reduce Motion:** cross-dissolve to the still final state (no bob, no shimmer), then the caption fades in (tested).
