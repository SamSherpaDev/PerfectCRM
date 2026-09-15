import { Controller } from "@hotwired/stimulus"

// Live preview on the template form. Debounces typing in the subject/body
// fields, POSTs them to the collection preview endpoint, and swaps the
// Turbo frame contents with the rendered result.
export default class extends Controller {
  static targets = ["subject", "body", "pane"]
  static values = { url: String }

  initialize() {
    this.revision = 0
  }

  disconnect() {
    clearTimeout(this.timer)
    this.revision += 1
  }

  changed() {
    this.revision += 1
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.refresh(), 350)
  }

  async refresh() {
    if (!this.hasPaneTarget || !this.urlValue) return
    const revision = ++this.revision
    const form = new FormData()
    if (this.hasSubjectTarget) form.append("template[subject]", this.subjectTarget.value)
    if (this.hasBodyTarget) form.append("template[body]", this.bodyTarget.value)
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        body: form,
        headers: { Accept: "text/html", ...(token ? { "X-CSRF-Token": token } : {}) }
      })
      if (!response.ok) return
      const html = await response.text()
      if (revision === this.revision) this.paneTarget.innerHTML = html
    } catch {
      // Preview is a nicety; the form still saves without it.
    }
  }
}
