import { Controller } from "@hotwired/stimulus"

// Quick-pick helpers for the call-scheduling popover form (Pacific dates and times).
export default class extends Controller {
  static targets = ["date", "time", "duration"]

  pickDate(event) {
    event.preventDefault()
    if (!this.hasDateTarget || !event.params.date) return
    this.dateTarget.value = event.params.date
    this.dateTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.dateTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  pickTime(event) {
    event.preventDefault()
    if (!this.hasTimeTarget || !event.params.time) return
    this.timeTarget.value = event.params.time
    this.timeTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.timeTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  pickDuration(event) {
    event.preventDefault()
    if (!this.hasDurationTarget || !event.params.minutes) return
    this.durationTarget.value = event.params.minutes
    this.durationTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.durationTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
