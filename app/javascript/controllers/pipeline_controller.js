// Pipeline board drag and drop (HTML5) with a keyboard alternative.
// Every card also carries a Move menu of plain links, so keyboard and
// touch users never need to drag. Dropping a lead on Lost opens the
// required-reason sheet; dropping on Won asks for confirmation first.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["card", "column", "lostDialog", "lostLead", "lostHeading"]
  static values = { moveUrl: String, autoLost: Boolean }

  connect() {
    if (this.autoLostValue && this.hasLostDialogTarget) this.lostDialogTarget.showModal()
  }

  dragstart(event) {
    const card = event.target.closest('[data-pipeline-target="card"]')
    if (!card) return
    this.dragged = {
      type: card.dataset.recordType,
      id: card.dataset.recordId,
      from: card.dataset.stage,
      name: card.dataset.recordName
    }
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move"
      try {
        event.dataTransfer.setData("text/plain", `${this.dragged.type}:${this.dragged.id}`)
      } catch { /* some browsers restrict setData to strings only */ }
    }
    requestAnimationFrame(() => card.classList.add("kcard-dragging"))
  }

  dragend() {
    this.element.querySelectorAll(".kcard-dragging").forEach((el) => el.classList.remove("kcard-dragging"))
    this.columnTargets.forEach((el) => el.classList.remove("col-drop-target"))
    this.ghost()?.remove()
    this.dragged = null
  }

  dragover(event) {
    if (!this.dragged) return
    const column = event.target.closest('[data-pipeline-target="column"]')
    if (!column) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move"
    this.columnTargets.forEach((el) => el.classList.toggle("col-drop-target", el === column))
    this.showGhost(column)
  }

  dragleave(event) {
    const column = event.target.closest('[data-pipeline-target="column"]')
    if (column && !column.contains(event.relatedTarget)) column.classList.remove("col-drop-target")
  }

  drop(event) {
    if (!this.dragged) return
    const column = event.target.closest('[data-pipeline-target="column"]')
    if (!column) return
    event.preventDefault()
    const to = column.dataset.stage
    const { type, id, from, name } = this.dragged
    this.dragend()
    if (to === from) return
    if (type === "lead" && to === "lost") {
      this.openLostSheet(id, name)
      return
    }
    if (type === "lead" && to === "won") {
      if (!window.confirm(`Convert ${name} to a client? Their whole timeline moves with them. This cannot be undone.`)) return
    }
    this.submitMove(type, id, to)
  }

  // Move-menu links carry data-to; the lost option opens the sheet instead.
  // Won carries a turbo_confirm already, so it passes straight through.
  move(event) {
    const link = event.target.closest("[data-to]")
    if (!link) return
    if (link.dataset.recordType === "lead" && link.dataset.to === "lost") {
      event.preventDefault()
      this.openLostSheet(link.dataset.recordId, link.dataset.recordName)
    }
  }

  openLostSheet(id, name) {
    if (!this.hasLostDialogTarget) return
    this.lostLeadTarget.value = id
    if (this.hasLostHeadingTarget && name) this.lostHeadingTarget.textContent = `Why did ${name} go quiet?`
    this.lostDialogTarget.showModal()
  }

  submitMove(type, id, to, extra = {}) {
    const form = document.createElement("form")
    form.method = "post"
    form.action = this.moveUrlValue
    const fields = { _method: "patch", to, ...(type === "lead" ? { lead_id: id } : { client_id: id }), ...extra }
    for (const [key, value] of Object.entries(fields)) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = key
      input.value = value
      form.appendChild(input)
    }
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) {
      const csrf = document.createElement("input")
      csrf.type = "hidden"
      csrf.name = "authenticity_token"
      csrf.value = token
      form.appendChild(csrf)
    }
    document.body.appendChild(form)
    form.requestSubmit()
  }

  showGhost(column) {
    const list = column.querySelector(".col-cards")
    if (!list || list.querySelector(".kcard-ghost")) return
    const ghost = document.createElement("div")
    ghost.className = "kcard kcard-ghost"
    ghost.setAttribute("aria-hidden", "true")
    ghost.innerHTML = "<span class='kcard-name'>Drop here</span>"
    list.appendChild(ghost)
    this._ghost = ghost
  }

  ghost() {
    return this._ghost
  }
}
