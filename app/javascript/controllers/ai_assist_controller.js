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
    const slot = form?.closest("turbo-frame")?.querySelector('[data-ai-assist-target="orbSlot"]')
    this.showOrb(slot, shaping ? "shaping" : "composing", shaping ? "Shaping…" : "Composing…")
    form?.addEventListener("turbo:submit-end", () => {
      if (slot) {
        slot.replaceChildren()
        slot.hidden = true
      }
    }, { once: true })
  }

  showOrb(slot, state, label) {
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

  useDraft() {
    if (!this.hasDraftBodyTarget) return
    const field = document.getElementById("message_body")
    if (!field) {
      this.setCopyStatus("The reply box is unavailable. Keep this draft until it is available.")
      return
    }
    const reply = field.closest('[data-controller~="reply-box"]')
    const composer = reply?.querySelector('[data-reply-box-target="composer"]')
    if (composer?.hidden) reply.querySelector('[data-reply-box-target="pill"]')?.click()
    const body = this.draftBodyTarget.value
    field.focus()
    field.setSelectionRange(0, field.value.length)
    field.dispatchEvent(new CustomEvent("template:insert", {
      bubbles: true, detail: { body, name: "AI draft", id: null }
    }))
    if (field.value !== body) {
      field.value = body
      const templateId = reply?.querySelector('[data-reply-box-target="templateId"]')
      if (templateId) templateId.value = ""
      field.dispatchEvent(new Event("input", { bubbles: true }))
    }
    field.dispatchEvent(new Event("change", { bubbles: true }))
    this.setCopyStatus("Draft added to the reply box. Review it and press Send there.")
  }

  async copy() {
    const body = this.hasDraftBodyTarget ? this.draftBodyTarget : null
    if (!body) return
    try {
      await navigator.clipboard.writeText(body.value)
      this.setCopyStatus("Draft copied.")
    } catch {
      body.select()
      this.setCopyStatus("Copy did not work - select the text by hand.")
    }
  }

  setCopyStatus(text) {
    if (this.hasCopyStatusTarget) this.copyStatusTarget.textContent = text
  }
}
