// Signature preview on the Settings page. Debounces typing in either
// signature field, asks the server to render the unsaved words exactly as
// the email will look, and swaps the preview in place. A freshly chosen
// logo file shows immediately through an object URL until it is saved.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["html", "text", "file", "output"]
  static values = { url: String }

  schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.render(), 400)
  }

  logoChanged() {
    if (this.logoUrl) URL.revokeObjectURL(this.logoUrl)
    this.logoUrl = null
    this.render()
  }

  async render() {
    const form = new FormData()
    if (this.hasTextTarget) form.append("setting[email_signature]", this.textTarget.value)
    if (this.hasHtmlTarget) form.append("setting[email_signature_html]", this.htmlTarget.value)

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": token || "" },
        body: form
      })
      if (!response.ok || response.redirected) return
      this.outputTarget.innerHTML = await response.text()
      this.applyLogo()
    } catch {
      // Preview stays on its last good render; saving still works.
    }
  }

  // The server previews the saved logo; a file picked but not yet saved
  // is shown in its place so the captain sees the real combination.
  applyLogo() {
    if (!this.hasFileTarget || !this.fileTarget.files?.length) return
    if (!this.logoUrl) this.logoUrl = URL.createObjectURL(this.fileTarget.files[0])
    const images = this.outputTarget.querySelectorAll("img")
    if (images.length === 0) {
      const image = document.createElement("img")
      image.src = this.logoUrl
      image.alt = "Signature logo"
      image.width = 200
      this.outputTarget.prepend(image)
    } else {
      images.forEach((image) => { image.src = this.logoUrl })
    }
  }
}
