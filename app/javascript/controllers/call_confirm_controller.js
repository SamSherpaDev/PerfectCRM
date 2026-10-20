import { Controller } from "@hotwired/stimulus"

// Explicit confirmation before logging an outbound call on a not-interested
// lead. Needed because the call forms use data-turbo="false" to preserve the
// #record-details redirect hash on phones.
export default class extends Controller {
  static values = {
    message: { type: String, default: "This lead is marked not interested. Log an outbound call anyway?" },
    notInterestedIds: { type: Array, default: [] }
  }

  confirm(event) {
    const message = event.currentTarget.dataset.turboConfirm || this.messageValue
    if (message && !window.confirm(message)) {
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

    if (!window.confirm(this.messageValue)) {
      event.preventDefault()
    }
  }
}
