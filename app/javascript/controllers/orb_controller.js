// Thinking-orb mount (docs/DESIGN.md 4.13): thin Stimulus wrapper around the
// vanilla port in `thinking_orbs.js`. Takes `state` (composing, shaping)
// and `size` (20, 64) values and mounts on a <canvas data-controller="orb">.
import { Controller } from "@hotwired/stimulus"
import { mountThinkingOrb } from "thinking_orbs"

const LABELS = { composing: "Composing…", shaping: "Shaping…" }

export default class extends Controller {
  static values = { state: String, size: Number, label: String }

  connect() {
    this.mount()
  }

  disconnect() {
    this.destroy?.()
    this.destroy = null
  }

  stateValueChanged() {
    this.element.setAttribute("aria-label", this.hasLabelValue ? this.labelValue : LABELS[this.orbState()])
    this.remount()
  }

  sizeValueChanged() {
    this.remount()
  }

  orbState() {
    return LABELS[this.stateValue] ? this.stateValue : "composing"
  }

  mount() {
    this.disconnect()
    this.destroy = mountThinkingOrb(this.element, { state: this.orbState(), size: this.sizeValue })
  }

  remount() {
    if (!this.element.isConnected) return
    this.mount()
  }
}
