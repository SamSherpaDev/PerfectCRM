// AI assistance (docs/DESIGN.md 4.13): shows the thinking orb beside the
// pressed button while the request runs, then clears it when Turbo swaps
// the frame. Composing for drafts and summaries, shaping for triage and
// suggestions. One orb per surface; never on a button.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["orbSlot", "draftBody", "copyStatus"]

  working(event) {
    const form = event.target.closest("form")
    const button = form?.querySelector('input[type="submit"], button[type="submit"]')
    const label = button?.value || button?.textContent || ""
    const shaping = /suggest|classif|triage/i.test(label)
    this.showOrb(shaping ? "shaping" : "composing", shaping ? "Shaping…" : "Composing…")
    if (button) button.disabled = true
  }

  showOrb(state, label) {
    const slot = this.hasOrbSlotTarget ? this.orbSlotTargets[0] : null
    if (!slot) return
    slot.hidden = false
    slot.innerHTML = ""
    const canvas = document.createElement("canvas")
    canvas.setAttribute("role", "img")
    canvas.setAttribute("aria-label", label)
    canvas.className = "orb"
    canvas.dataset.controller = "orb"
    canvas.dataset.orbStateValue = state
    canvas.dataset.orbSizeValue = "20"
    canvas.dataset.orbLabelValue = label
    slot.appendChild(canvas)
    const text = document.createElement("span")
    text.className = "hint"
    text.setAttribute("role", "status")
    text.textContent = label
    slot.appendChild(text)
  }

  async copy() {
    const body = this.hasDraftBodyTarget ? this.draftBodyTarget : null
    if (!body) return
    try {
      await navigator.clipboard.writeText(body.value)
      this.setCopyStatus("Copied. Paste it wherever you send mail.")
    } catch {
      body.select()
      this.setCopyStatus("Copy did not work — select the text by hand.")
    }
  }

  setCopyStatus(text) {
    if (this.hasCopyStatusTarget) this.copyStatusTarget.textContent = text
  }
}
