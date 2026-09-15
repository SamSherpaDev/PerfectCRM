/*
 * MIT License
 *
 * Copyright (c) 2026 Jakub Antalik
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

// Thinking orbs (docs/DESIGN.md 4.13, Appendix B). Vanilla port of two of the
// nine thinking-orbs states (github.com/Jakubantalik/thinking-orbs) — no
// React, plain 2D canvas arcs. What stays verbatim from the library:
// BASE_PROFILES.ribbon/.morph, PRESETS for ribbon/morph at 64 and 20,
// scaleCounts, scaleRadii, fibDir, makeProj, radiusScale, finalizeFrame,
// frameRibbon, frameMorph, the reduced-motion frame at t = 0.6, the
// offscreen and hidden-tab pause, the DPR cap of 2. What changes: the
// painter (one Washi brand colour per scheme, depth as alpha) and theme
// resolution (nearest [data-scheme] ancestor, then prefers-color-scheme).
//
// Mount API: mountThinkingOrb(canvas, { state, size }) -> destroy().
// `state` is "composing" or "shaping"; `size` is 64 or 20 CSS px.

// Shared clock: every mounted orb reads the same origin, so all orbs on
// the page stay in phase.
const CLOCK_ORIGIN = performance.now()

// --- core primitives (thinking-orbs src/engine/core.ts) --------------------
function fibDir(i, n) {
  const golden = Math.PI * (3 - Math.sqrt(5))
  const y = 1 - (2 * (i + 0.5)) / n
  const rad = Math.sqrt(1 - y * y)
  const a = i * golden
  return [rad * Math.cos(a), y, rad * Math.sin(a)]
}

function makeProj(yaw, tilt, cx, cy, scale) {
  const st = Math.sin(tilt)
  const ct = Math.cos(tilt)
  const sy = Math.sin(yaw)
  const cyw = Math.cos(yaw)
  return (x, y, z) => {
    const x1 = x * cyw + z * sy
    const z1 = -x * sy + z * cyw
    const y1 = y * ct - z1 * st
    const z2 = y * st + z1 * ct
    return [cx + x1 * scale, cy - y1 * scale, z2]
  }
}

function finalizeFrame(dots, lines, rMin = 0.3) {
  const visible = []
  for (const d of dots) {
    if ((d.a ?? 1) < 0.02) continue
    d.r = Math.max(rMin, d.r)
    visible.push(d)
  }
  visible.sort((a, b) => a.z - b.z)
  return { dots: visible, lines: (lines || []).filter((l) => (l.a ?? 1) >= 0.02) }
}

function radiusScale(size, pow) {
  return (size / 300) ** pow
}

// --- density profiles (thinking-orbs src/engine/profiles.ts) ---------------
// Only the ribbon + morph rows and the multiplier machinery they use.
const COUNT_PAIRS = [["lanes", "segs"]]
const COUNT_KEYS = ["ghostN"]
const RADIUS_KEYS = ["rBase", "rDepth", "rDot"]

function scaleCounts(opts, scale) {
  const out = { ...opts }
  const done = new Set()
  const rt = Math.sqrt(scale)
  for (const [a, b] of COUNT_PAIRS) {
    const va = out[a]
    const vb = out[b]
    if (va != null && vb != null && !done.has(a) && !done.has(b)) {
      out[a] = Math.max(2, Math.round(va * rt))
      out[b] = Math.max(2, Math.round(vb * rt))
      done.add(a)
      done.add(b)
    }
  }
  for (const k of COUNT_KEYS) {
    const v = out[k]
    if (v != null && v !== 0 && !done.has(k)) out[k] = Math.max(1, Math.round(v * scale))
  }
  if (out.iconD != null) out.iconD = Math.max(0.02, out.iconD * scale)
  return out
}

function scaleRadii(opts, scale) {
  const out = { ...opts }
  for (const k of RADIUS_KEYS) {
    const v = out[k]
    if (v != null) out[k] = v * scale
  }
  out.rSizeMul = (out.rSizeMul ?? 1) * scale
  return out
}

const BASE_PROFILES = {
  ribbon: { lanes: 5, segs: 88, ghostN: 150, rBase: 1.1, rDepth: 1.7, rsPow: 0.6, rMin: 0.3 },
  morph: { rDot: 0.021, iconD: 1, rMin: 0.25 }
}

// --- shipped tunings (thinking-orbs src/presets.ts), ribbon + morph only ---
const PRESETS = {
  ribbon: {
    64: { speed: 2.34, count: 0.25, size: 0.85, extra: { spin: 0, bandMul: 3.9, wobMul: 1 } },
    20: { speed: 3.12, count: 0.051, size: 1.073, extra: { spin: 0, bandMul: 4.94, wobMul: 1 } }
  },
  morph: {
    64: { speed: 2.405, count: 0.702, size: 0.395, extra: { spread: 1.45 } },
    20: { speed: 2.08, count: 0.53, size: 1.011, extra: { spread: 1.45 } }
  }
}

const STATE_TO_MODE = { composing: "ribbon", shaping: "morph" }

function resolvePreset(state, size) {
  const mode = STATE_TO_MODE[state]
  const preset = PRESETS[mode][size]
  let opts = { ...BASE_PROFILES[mode] }
  if (preset.count !== 1) opts = scaleCounts(opts, preset.count)
  if (preset.size !== 1) opts = scaleRadii(opts, preset.size)
  if (preset.extra) opts = { ...opts, ...preset.extra }
  return { mode, speed: preset.speed, opts }
}

// --- ribbon geometry (thinking-orbs src/engine/ribbon.ts) ------------------
// An undulating sash of parallel strands on a great circle: composing.
function frameRibbon(size, t, o) {
  const cx = size / 2
  const cy = size / 2
  const R = (size / 2) * 0.78
  const spin = o.spin ?? 1
  const camTilt = 0.3
  const pt = makeProj(t * 0.1 * spin, camTilt, cx, cy, 1)
  const rs = radiusScale(size, o.rsPow ?? 0.6)

  const dots = []
  const ghostN = o.ghostN ?? 150
  for (let i = 0; i < ghostN; i++) {
    const d = fibDir(i, ghostN)
    const [px, py, z] = pt(d[0] * R, d[1] * R, d[2] * R)
    const depth = (z / R + 1) / 2
    dots.push({ x: px, y: py, z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth })
  }

  const ya = t * 0.24 * spin
  const ta = 0.55 + 0.3 * Math.sin(t * 0.18) * spin
  const ux = Math.cos(ya)
  const uy = 0
  const uz = Math.sin(ya)
  const vx = -uz * Math.sin(ta)
  const vy = Math.cos(ta)
  const vz = ux * Math.sin(ta)
  const nx = uy * vz - uz * vy
  const ny = uz * vx - ux * vz
  const nz = ux * vy - uy * vx

  const baseR = R
  const baseLanes = o.lanes ?? 5
  const segs = o.segs ?? 88
  const lanes = Math.max(1, Math.round(baseLanes * (o.bandMul ?? 1)))
  for (let w = 0; w < lanes; w++) {
    const laneOff = (w - (lanes - 1) / 2) * 0.075
    const edge = Math.abs(w - (lanes - 1) / 2) / Math.max(1, (lanes - 1) / 2)
    for (let k = 0; k < segs; k++) {
      const a = (k / segs) * 2 * Math.PI
      const wob =
        (0.16 * Math.sin(a * 3 - t * 1.7 + w * 0.22) + 0.07 * Math.sin(a * 5 + t * 1.1)) *
        (o.wobMul ?? 1)
      const off = laneOff + wob
      const x = ux * Math.cos(a) + vx * Math.sin(a) + nx * off
      const y = uy * Math.cos(a) + vy * Math.sin(a) + ny * off
      const z = uz * Math.cos(a) + vz * Math.sin(a) + nz * off
      const l = Math.sqrt(x * x + y * y + z * z)
      const [px, py, zr] = pt((x / l) * baseR, (y / l) * baseR, (z / l) * baseR)
      const depth = (zr / R + 1) / 2
      dots.push({
        x: px,
        y: py,
        z: zr,
        r: ((o.rBase ?? 1.1) + (o.rDepth ?? 1.7) * depth) * (1 - 0.25 * edge) * rs,
        white: 0.52 - 0.44 * depth + 0.18 * edge,
        a: 0.4 + 0.6 * depth
      })
    }
  }
  return finalizeFrame(dots, [], o.rMin)
}

// --- morph geometry (thinking-orbs src/engine/morph.ts) --------------------
// A dotted outline cycling circle → triangle → square: shaping.
function smoothE(x) {
  return x * x * (3 - 2 * x)
}

function polyPath(verts) {
  const V = verts.length
  const L = []
  let total = 0
  for (let i = 0; i < V; i++) {
    const a = verts[i]
    const b = verts[(i + 1) % V]
    const l = Math.hypot(b[0] - a[0], b[1] - a[1])
    L.push(l)
    total += l
  }
  return (f) => {
    let target = f * total
    let i = 0
    while (target > L[i] && i < V - 1) {
      target -= L[i]
      i++
    }
    const a = verts[i]
    const b = verts[(i + 1) % V]
    const ff = L[i] ? Math.min(1, target / L[i]) : 0
    return [a[0] + (b[0] - a[0]) * ff, a[1] + (b[1] - a[1]) * ff]
  }
}

const CIRCLE = (f) => {
  const a = -Math.PI / 2 + f * 2 * Math.PI
  return [Math.cos(a) * 0.24, Math.sin(a) * 0.24]
}
const TRIANGLE = polyPath([
  [0.0, -0.26],
  [0.24, 0.16],
  [-0.24, 0.16]
])
const SQUARE = polyPath([
  [0, -0.2],
  [0.2, -0.2],
  [0.2, 0.2],
  [-0.2, 0.2],
  [-0.2, -0.2]
])
const CYCLE = [CIRCLE, TRIANGLE, SQUARE]

function morphN(d) {
  return Math.max(6, Math.round(34 * d))
}

const HOLD = 1.4
const MORPH = 0.9
const SEG = HOLD + MORPH

function frameMorph(size, t, o) {
  const K = CYCLE.length
  const tc = t % (SEG * K)
  const k = Math.floor(tc / SEG)
  const local = tc - k * SEG
  const m = local > HOLD ? smoothE((local - HOLD) / MORPH) : 0
  const sprd = o.spread ?? 1

  const pA = CYCLE[k]
  const pB = CYCLE[(k + 1) % K]
  const M = 160
  const pts = []
  for (let i = 0; i < M; i++) {
    const f = i / M
    const a = pA(f)
    const b = pB(f)
    pts.push([(a[0] + (b[0] - a[0]) * m) * sprd, (a[1] + (b[1] - a[1]) * m) * sprd])
  }
  const L = []
  let total = 0
  for (let i = 0; i < M; i++) {
    const a = pts[i]
    const b = pts[(i + 1) % M]
    const l = Math.hypot(b[0] - a[0], b[1] - a[1])
    L.push(l)
    total += l
  }

  const n = morphN(o.iconD ?? 1)
  const re = (o.rDot ?? 0.021) * 1.35 * sprd
  const pulse = 1 + 0.02 * Math.sin(local * 3.1)

  const dots = []
  const c2 = size / 2
  let seg = 0
  let acc = 0
  for (let k2 = 0; k2 < n; k2++) {
    const target = (k2 / n) * total
    while (acc + L[seg] < target && seg < M - 1) {
      acc += L[seg]
      seg++
    }
    const a = pts[seg]
    const b = pts[(seg + 1) % M]
    const f = L[seg] ? Math.min(1, (target - acc) / L[seg]) : 0
    const x = (a[0] + (b[0] - a[0]) * f) * pulse
    const y = (a[1] + (b[1] - a[1]) * f) * pulse
    dots.push({ x: c2 + x * size, y: c2 + y * size, z: 0, r: Math.max(0.35, re * size), white: 0.1 })
  }
  return finalizeFrame(dots, [], o.rMin)
}

const MODE_FRAMES = { ribbon: frameRibbon, morph: frameMorph }

// --- Washi painter ----------------------------------------------------------
// The library carries depth as grey; the CRM carries it as alpha on the one
// brand colour: ochre on paper, cream on ink. No grey dots anywhere.
const INKS = { paper: [201, 111, 26], night: [252, 250, 238] }

function paintWashi(ctx, frame, scheme) {
  const [r, g, b] = INKS[scheme] || INKS.paper
  for (const d of frame.dots) {
    const w = Math.min(1, Math.max(0, d.white))
    const alpha = (d.a ?? 1) * (1 - 0.8 * w)
    if (alpha < 0.02) continue
    ctx.fillStyle = `rgba(${r},${g},${b},${alpha.toFixed(3)})`
    ctx.beginPath()
    ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2)
    ctx.fill()
  }
}

// --- theme ------------------------------------------------------------------
// Nearest [data-scheme] ancestor, then prefers-color-scheme.
function resolveScheme(canvas) {
  const holder = typeof canvas.closest === "function" ? canvas.closest("[data-scheme]") : null
  if (holder) return holder.dataset.scheme === "night" ? "night" : "paper"
  if (typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches) {
    return "night"
  }
  return "paper"
}

// --- mount ------------------------------------------------------------------
const STATIC_T = 0.6

export function mountThinkingOrb(canvas, { state = "composing", size = 64 } = {}) {
  const orbState = STATE_TO_MODE[state] ? state : "composing"
  const orbSize = size === 64 ? 64 : 20
  const dpr = Math.min(2, (typeof devicePixelRatio !== "undefined" && devicePixelRatio) || 1)
  canvas.width = Math.round(orbSize * dpr)
  canvas.height = Math.round(orbSize * dpr)
  canvas.style.width = `${orbSize}px`
  canvas.style.height = `${orbSize}px`

  const resolved = resolvePreset(orbState, orbSize)
  const draw = MODE_FRAMES[resolved.mode]
  const ctx = canvas.getContext("2d")

  let scheme = resolveScheme(canvas)
  const paint = (tSec) => {
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, orbSize, orbSize)
    paintWashi(ctx, draw(orbSize, tSec, resolved.opts), scheme)
  }
  const now = () => ((performance.now() - CLOCK_ORIGIN) / 1000) * resolved.speed

  const reducedQuery =
    typeof matchMedia !== "undefined" ? matchMedia("(prefers-reduced-motion: reduce)") : null

  let raf = 0
  let running = false
  let visible = typeof IntersectionObserver === "undefined"
  const loop = () => {
    paint(now())
    if (running) raf = requestAnimationFrame(loop)
  }
  const begin = () => {
    if (running || reducedQuery?.matches || !visible || document.visibilityState === "hidden") return
    running = true
    raf = requestAnimationFrame(loop)
  }
  const finish = () => {
    running = false
    cancelAnimationFrame(raf)
  }
  const onVisibility = () => {
    if (document.visibilityState === "hidden") finish()
    else if (visible) begin()
  }

  // The scheme follows [data-scheme] flips live (Settings applies instantly).
  const schemeObserver = new MutationObserver(() => {
    const next = resolveScheme(canvas)
    if (next !== scheme) {
      scheme = next
      if (reducedQuery?.matches) paint(STATIC_T)
    }
  })
  const root = canvas.getRootNode?.() ?? document
  if (typeof MutationObserver !== "undefined" && root.observe) {
    schemeObserver.observe(root === document ? document.documentElement : root, {
      attributes: true,
      attributeFilter: ["data-scheme"],
      subtree: true
    })
  }
  const systemQuery =
    typeof matchMedia !== "undefined" ? matchMedia("(prefers-color-scheme: dark)") : null
  const onSystem = () => {
    scheme = resolveScheme(canvas)
    if (reducedQuery?.matches) paint(STATIC_T)
  }
  systemQuery?.addEventListener?.("change", onSystem)
  const onMotion = () => {
    if (reducedQuery?.matches) {
      finish()
      paint(STATIC_T)
    } else {
      begin()
    }
  }
  reducedQuery?.addEventListener?.("change", onMotion)

  let intersection = null
  paint(reducedQuery?.matches ? STATIC_T : now())
  document.addEventListener("visibilitychange", onVisibility)
  if (typeof IntersectionObserver !== "undefined") {
    intersection = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting
      if (visible && document.visibilityState !== "hidden") begin()
      else finish()
    })
    intersection.observe(canvas)
  } else {
    begin()
  }

  return () => {
    finish()
    intersection?.disconnect()
    schemeObserver.disconnect()
    systemQuery?.removeEventListener?.("change", onSystem)
    reducedQuery?.removeEventListener?.("change", onMotion)
    document.removeEventListener("visibilitychange", onVisibility)
  }
}
