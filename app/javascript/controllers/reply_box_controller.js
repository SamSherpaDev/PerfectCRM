import { Controller } from "@hotwired/stimulus"

// Docked reply box (reply_box/_box): one-tap template inserts with live
// placeholder values and a booking select that swaps the context.
export default class extends Controller {
  static values = { defaultContext: Object, bookingContexts: Object, contextUrl: String, open: Boolean }
  static targets = [
    "form", "conversation", "templateId", "to", "subject", "body",
    "booking", "bookingPanel", "bookingReference", "status", "details", "pill", "composer"
  ]

  connect() {
    // The phone keeps the thread clear: the composer hides behind the
    // Reply pill until the captain opens it. Desktop always shows it.
    if (this.hasComposerTarget && this.hasPillTarget) {
      // A nudge link (?nudge_booking_id=, or a prefilled ?template= that the
      // server marked open) arrives with the composer already filled, so
      // the sheet opens on its own. The organization page keeps its
      // Suggested message card on top, so its box stays shut here.
      const phone = window.innerWidth < 750
      const params = new URL(window.location.href).searchParams
      const prefilled = this.openValue || params.has("nudge_booking_id")
      const collapsed = phone && !prefilled
      this.composerTarget.hidden = collapsed
      this.pillTarget.hidden = !collapsed
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
      const response = await fetch(await this.urlWithContext(url), {
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
    this.updateBookingReference()
    this.setStatus("Placeholders now fill from the selected booking.")
  }

  async recipientChanged() {
    try {
      await this.refreshContext()
    } catch {
      this.setStatus("Could not load recipient context. Please try again.")
    }
  }

  async refreshContext() {
    const recipient = this.toTarget.value
    const url = new URL(this.contextUrlValue, window.location.origin)
    url.searchParams.set("to", recipient)
    url.searchParams.set("booking_id", this.bookingTarget.value)
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) throw new Error("Context unavailable")
    const data = await response.json()
    if (recipient !== this.toTarget.value) throw new Error("Recipient changed")
    this.defaultContextValue = data.context
    this.bookingContextsValue = data.booking_contexts
    this.bookingTarget.replaceChildren(...data.bookings.map((booking) =>
      new Option(booking.label, booking.id, false, booking.id === data.selected_booking_id)))
    this.bookingPanelTarget.hidden = data.bookings.length < 2
    this.updateBookingReference()
  }

  updateBookingReference() {
    const name = this.activeContext().booking_owner_name
    this.bookingReferenceTarget.hidden = !name
    this.bookingReferenceTarget.textContent = name ? `Booking reference: ${name}'s booking.` : ""
  }

  async urlWithContext(url) {
    await this.refreshContext()
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
