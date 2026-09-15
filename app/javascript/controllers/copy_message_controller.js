import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["text", "status"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textTarget.value)
      this.statusTarget.textContent = "Message copied."
    } catch {
      this.textTarget.classList.remove("sr-only")
      this.textTarget.focus()
      this.textTarget.select()
      this.statusTarget.textContent = "Select and copy the message below."
    }
  }
}
