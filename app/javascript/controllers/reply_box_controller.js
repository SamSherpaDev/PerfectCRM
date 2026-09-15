import { Controller } from "@hotwired/stimulus"

// Docked reply box (reply_box/_box): one-tap template inserts with live
// placeholder values and a booking select that swaps the context.
export default class extends Controller {
  static values = { defaultContext: Object, bookingContexts: Object }
  static targets = [
    "form", "conversation", "templateId", "to", "subject", "body",
    "booking", "status", "details", "pill", "composer"
  ]

  connect() {
    // The phone keeps the thread clear: the composer hides behind the
    // Reply pill until the captain opens it. Desktop always shows it.
    if (this.hasComposerTarget && this.hasPillTarget) {
      const phone = window.innerWidth < 750
      this.composerTarget.hidden = phone
      this.pillTarget.hidden = !phone
    }
    // The phone keeps the docked box compact: envelope fields hide behind
    // Details until the captain opens them. Desktop starts expanded.
    if (this.hasDetailsTarget && window.innerWidth < 750) {
      this.detailsTarget.removeAttribute("open")
    }
    this.onTemplateInsert = (event) => {
      if (this.element.contains(event.target)) this.applyInsert(event.detail)
    }
    window.addEventListener("template:insert", this.onTemplateInsert)
  }

  disconnect() {
    window.removeEventListener("template:insert", this.onTemplateInsert)
  }

  // A most-used chip: fetch the rendered template with live context, then
  // fill the box exactly like a picker insert.
  async insertTemplate(event) {
    const button = event.currentTarget
    const url = button.dataset.url
    if (!url) return
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    button.disabled = true
    try {
      const response = await fetch(this.urlWithContext(url), {
        method: "POST",
        headers: { Accept: "application/json", ...(token ? { "X-CSRF-Token": token } : {}) }
      })
      if (!response.ok) throw new Error("Insertion failed")
      this.applyInsert(await response.json())
    } catch {
      this.setStatus("Could not insert template. Please try again.")
    } finally {
      button.disabled = false
    }
  }

  applyInsert(data) {
    if (!data) return
    if (data.subject && this.hasSubjectTarget) this.subjectTarget.value = data.subject
    if (data.body && this.hasBodyTarget) this.insertAtCursor(this.bodyTarget, data.body)
    if (this.hasTemplateIdTarget) this.templateIdTarget.value = data.id ?? ""
    const name = data.name ?? "template"
    this.setStatus(`Inserted ${name} - review and press Send.`)
  }

  // The floating Reply pill opens the composer as a bottom sheet; Close
  // puts it back behind the pill.
  toggleComposer() {
    if (!this.hasComposerTarget || !this.hasPillTarget) return
    const opening = this.composerTarget.hidden
    this.composerTarget.hidden = !opening
    this.pillTarget.hidden = opening
    if (opening && this.hasBodyTarget) this.bodyTarget.focus({ preventScroll: true })
  }

  // Another booking means another trip/dates/balance behind {{…}}: point
  // the embedded picker at the new context so the next insert fills right.
  bookingChanged() {
    const picker = this.element.querySelector('[data-controller="template-picker"]')
    if (picker) {
      picker.setAttribute("data-template-picker-context-value", JSON.stringify(this.activeContext()))
    }
    this.setStatus("Placeholders now fill from the selected booking.")
  }

  urlWithContext(url) {
    const target = new URL(url, window.location.origin)
    for (const [key, value] of Object.entries(this.activeContext())) {
      if (value !== null && value !== undefined && value !== "") {
        target.searchParams.set(`context[${key}]`, value)
      }
    }
    return target.toString()
  }

  activeContext() {
    const bookingId = this.hasBookingTarget ? this.bookingTarget.value : null
    const all = this.bookingContextsValue || {}
    if (bookingId && all[bookingId]) return all[bookingId]
    return this.defaultContextValue || {}
  }

  insertAtCursor(field, text) {
    field.focus()
    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length
    field.value = field.value.slice(0, start) + text + field.value.slice(end)
    const cursor = start + text.length
    field.selectionStart = field.selectionEnd = cursor
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
