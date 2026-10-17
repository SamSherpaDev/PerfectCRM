import { Controller } from "@hotwired/stimulus"

// Phone tab rows scroll sideways (docs/DESIGN.md 11): keep the current tab in
// view and fade whichever edge hides more tabs.
export default class extends Controller {
  connect() {
    this.update = this.update.bind(this)
    this.reveal()
    this.update()
    this.element.addEventListener("scroll", this.update, { passive: true })
    window.addEventListener("resize", this.update)
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.update)
    window.removeEventListener("resize", this.update)
  }

  reveal() {
    const current = this.element.querySelector("[aria-current]")
    if (!current || this.element.scrollWidth <= this.element.clientWidth) return

    const row = this.element.getBoundingClientRect()
    const tab = current.getBoundingClientRect()
    if (tab.left < row.left || tab.right > row.right) {
      this.element.scrollLeft += tab.left - row.left - (row.width - tab.width) / 2
    }
  }

  update() {
    const { scrollLeft, clientWidth, scrollWidth } = this.element
    this.element.classList.toggle("tabs-more-start", scrollLeft > 1)
    this.element.classList.toggle("tabs-more-end", scrollLeft + clientWidth < scrollWidth - 1)
  }
}
