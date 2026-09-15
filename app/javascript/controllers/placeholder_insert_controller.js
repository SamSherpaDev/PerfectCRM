import { Controller } from "@hotwired/stimulus"

// Placeholder chooser on the template form. Each button carries its
// {{token}} in data-token; tapping drops it where the cursor sits in the
// subject or body field last touched.
export default class extends Controller {
  static targets = ["field"]

  track(event) {
    this.activeField = event.target
  }

  insert(event) {
    const token = event.currentTarget.dataset.token
    if (!token) return
    const field = this.activeField && this.hasFieldTarget && this.fieldTargets.includes(this.activeField)
      ? this.activeField
      : this.fieldTargets.find((element) => element.name.includes("body"))
    if (!field) return

    field.focus()
    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length
    field.value = field.value.slice(0, start) + token + field.value.slice(end)
    const cursor = start + token.length
    field.selectionStart = field.selectionEnd = cursor
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
