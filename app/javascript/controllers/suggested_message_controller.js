import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["body", "status"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.bodyTarget.value)
      this.statusTarget.textContent = "Message copied."
    } catch {
      this.bodyTarget.focus()
      this.bodyTarget.select()
      this.statusTarget.textContent = "Select Copy to copy the highlighted message."
    }
  }
}
