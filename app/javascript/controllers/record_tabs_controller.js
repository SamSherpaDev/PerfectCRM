import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.activate(this.tabForHash(window.location.hash) || "thread")
  }

  show(event) {
    this.activate(event.currentTarget.dataset.tab)
  }

  tabForHash(hash) {
    const id = (hash || "").replace(/^#/, "")
    if (!id) return null
    const target = document.getElementById(id)
    const panel = target?.closest("[data-tab]")
    if (!panel) return null
    return this.panelTargets.some((candidate) => candidate.dataset.tab === panel.dataset.tab)
      ? panel.dataset.tab
      : null
  }

  activate(name) {
    if (!this.panelTargets.some((panel) => panel.dataset.tab === name)) name = "thread"
    this.tabTargets.forEach((tab) => {
      const on = tab.dataset.tab === name
      tab.classList.toggle("tab-on", on)
      if (on) tab.setAttribute("aria-current", "true")
      else tab.removeAttribute("aria-current")
    })
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("tab-off", panel.dataset.tab !== name)
    })
  }
}
