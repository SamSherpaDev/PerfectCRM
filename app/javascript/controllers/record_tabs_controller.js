import { Controller } from "@hotwired/stimulus"

// Phone tabs on the lead and client record pages (records/_tabs): Thread,
// Details, Files & dates over the same three columns. Thread is the default;
// the last tab opened is remembered per record. A deep link into a card
// (the composer, a timeline stone, the pager) opens its tab, so a nudge
// link from Files lands on the prefilled composer instead of a hidden
// panel. Above 750px the CSS ignores the tab-off class and shows every
// column.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { key: String }

  connect() {
    const linked = this.tabForHash(window.location.hash)
    if (linked) {
      this.activate(linked, true)
      return
    }
    let name = "thread"
    try {
      name = localStorage.getItem(this.keyValue) || "thread"
    } catch {
      name = "thread"
    }
    this.activate(name, false)
  }

  show(event) {
    this.activate(event.currentTarget.dataset.tab, true)
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

  activate(name, remember) {
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
    if (remember) {
      try {
        localStorage.setItem(this.keyValue, name)
      } catch {
        // Private mode or storage disabled: the tab still switches.
      }
    }
  }
}
