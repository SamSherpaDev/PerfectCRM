import { Controller } from "@hotwired/stimulus"

// One-tap insert for the templates/_picker partial. Tapping Insert records a
// use (so dead templates get pruned) and emits a window "template:insert"
// event with {subject, body} detail; the reply box listens and fills itself.
export default class extends Controller {
  static targets = ["query"]

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
    const url = button.dataset.url
    if (!url) return
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    button.disabled = true
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { Accept: "application/json", ...(token ? { "X-CSRF-Token": token } : {}) }
      })
      if (!response.ok) return
      const data = await response.json()
      window.dispatchEvent(new CustomEvent("template:insert", { detail: data, bubbles: true }))
      const original = button.textContent
      button.textContent = `Inserted: ${data.name ?? button.dataset.name ?? "template"}`
      setTimeout(() => {
        button.textContent = original
        button.disabled = false
      }, 1200)
    } catch {
      button.disabled = false
    }
  }
}
