import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query", "error"]

  connect() {
    // Frame reloads after a search replace the field; hand the cursor back
    // so the captain can keep typing one-handed.
    if (this.hasQueryTarget && this.queryTarget.value) {
      this.queryTarget.focus()
      const end = this.queryTarget.value.length
      this.queryTarget.setSelectionRange(end, end)
    }
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.querySelector("form")?.requestSubmit(), 300)
  }

  async insert(event) {
    const button = event.currentTarget
    if (!button.dataset.url) return
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    button.disabled = true
    this.errorTarget.textContent = ""
    this.errorTarget.hidden = true
    try {
      const url = await this.urlWithContext(button.dataset.url)
      const response = await fetch(url, {
        method: "POST",
        headers: { Accept: "application/json", ...(token ? { "X-CSRF-Token": token } : {}) }
      })
      if (!response.ok) throw new Error("Insertion failed")
      const data = await response.json()
      this.element.dispatchEvent(new CustomEvent("template:insert", { detail: data, bubbles: true }))
      const original = button.textContent
      button.textContent = `Inserted: ${data.name ?? button.dataset.name ?? "template"}`
      setTimeout(() => {
        button.textContent = original
        button.disabled = false
      }, 1200)
    } catch {
      button.disabled = false
      this.errorTarget.textContent = "Could not insert template. Please try again."
      this.errorTarget.hidden = false
    }
  }

  // Live placeholder values ride along so the insert arrives filled.
  // Without them unknown values render [missing: …] by design.
  urlWithContext(url) {
    if (!url) return url
    const composer = this.element.closest('[data-controller~="reply-box"]')
    const controller = composer && this.application.getControllerForElementAndIdentifier(composer, "reply-box")
    if (controller) return controller.urlWithContext(url)
    let context = {}
    try {
      context = JSON.parse(this.element.dataset.templatePickerContextValue || "{}") || {}
    } catch {
      context = {}
    }
    const target = new URL(url, window.location.origin)
    for (const [key, value] of Object.entries(context)) {
      if (value !== null && value !== undefined && value !== "") {
        target.searchParams.set(`context[${key}]`, value)
      }
    }
    return target.toString()
  }
}
