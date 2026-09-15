import { Controller } from "@hotwired/stimulus"

// Docked reply box (reply_box/_box): one-tap template inserts with live
// placeholder values, basic *bold* / _italic_ / list formatting, a booking
// select that swaps the placeholder context, and the assist slot toggle.
// The AI drafting task owns [data-assist]; this controller only shows it.
export default class extends Controller {
  static values = { defaultContext: Object, bookingContexts: Object }
  static targets = [
    "form", "conversation", "templateId", "to", "subject", "body",
    "booking", "status", "assist", "details", "pill", "composer"
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
    this.setStatus(`Inserted ${name} — review and press Send.`)
  }

  // Wrap the selection (or drop markers at the cursor) for *bold* and
  // _italic_; prefix each selected line for lists.
  format(event) {
    const field = this.hasBodyTarget ? this.bodyTarget : null
    if (!field) return
    const { wrap, prefix } = event.currentTarget.dataset
    field.focus()
    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length
    const selected = field.value.slice(start, end)
    let replacement, cursor
    if (prefix) {
      const lines = (selected || "").split("\n").map((line) => `${prefix}${line}`)
      replacement = lines.join("\n")
      cursor = start + replacement.length
    } else if (wrap) {
      replacement = `${wrap}${selected}${wrap}`
      cursor = selected ? start + replacement.length : start + wrap.length
    } else {
      return
    }
    field.value = field.value.slice(0, start) + replacement + field.value.slice(end)
    field.selectionStart = field.selectionEnd = cursor
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  toggleAssist() {
    if (!this.hasAssistTarget) return
    this.assistTarget.hidden = !this.assistTarget.hidden
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
