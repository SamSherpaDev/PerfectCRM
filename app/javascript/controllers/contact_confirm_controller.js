import { Controller } from "@hotwired/stimulus"

// Explicit confirmation before contacting a not-interested lead from a form
// that uses data-turbo="false", where Turbo's data-turbo-confirm never runs:
// the call forms (to preserve the #record-details redirect hash on phones)
// and the new-quote builder.
export default class extends Controller {
  static values = {
    message: String,
    notInterestedIds: { type: Array, default: [] }
  }

  confirm(event) {
    if (!window.confirm(this.messageValue)) {
      event.preventDefault()
    }
  }

  confirmDetails(event) {
    const form = event.currentTarget
    const directionField = form.querySelector("[name='direction']")
    const direction = directionField ? directionField.value : "outbound"
    if (direction !== "outbound") return

    const inquiryField = form.querySelector("[name='inquiry_id']")
    if (inquiryField && this.notInterestedIdsValue.length > 0) {
      const selectedId = Number.parseInt(inquiryField.value, 10)
      if (!this.notInterestedIdsValue.includes(selectedId)) return
    }

    this.confirm(event)
  }
}
