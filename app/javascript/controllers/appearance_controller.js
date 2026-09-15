import { Controller } from "@hotwired/stimulus"

// Appearance choice on the Settings page. Applies the chosen scheme to the
// document immediately for zero-latency feedback, then submits the enclosing
// form so the choice is persisted with no further action.
export default class extends Controller {
  static targets = ["status"]

  apply(event) {
    const value = event.target?.value
    if (value !== "paper" && value !== "night") return

    document.documentElement.dataset.scheme = value
    if (document.body) document.body.dataset.scheme = value
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta) meta.setAttribute("content", value === "night" ? "#14110e" : "#fcfaee")

    this.statusTarget.textContent = "Saving appearance…"
    this.element.requestSubmit()
  }
}
