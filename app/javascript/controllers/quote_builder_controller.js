// Quote builder lines: add/remove rows and keep the totals live.
// Money math stays server-side on save; this only previews the sums.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rows", "template", "total", "count", "inclusionsEdited"]

  connect() {
    this.recalc()
  }

  editInclusions() {
    this.inclusionsEditedTarget.value = "1"
  }

  editPrice(event) {
    event.target.closest("[data-line-row]").querySelector("[data-price-edited]").value = "1"
    this.recalc()
  }

  add(event) {
    event.preventDefault()
    const html = this.templateTarget.innerHTML.replaceAll("__INDEX__", Date.now())
    this.rowsTarget.insertAdjacentHTML("beforeend", html)
    const row = this.rowsTarget.lastElementChild
    row.querySelector("input[data-description]")?.focus()
    this.recalc()
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-line-row]")
    if (!row) return
    const destroy = row.querySelector("input[data-destroy]")
    if (destroy) {
      destroy.value = "1"
      row.classList.add("hidden")
    } else {
      row.remove()
    }
    this.recalc()
  }

  recalc() {
    let total = 0
    let guests = 0
    this.rowsTarget.querySelectorAll("[data-line-row]:not(.hidden)").forEach((row) => {
      const qty = Number(row.querySelector("input[data-qty]")?.value || 0)
      const price = row.querySelector("input[data-each]")?.value.trim() || ""
      const each = price === "" || /^[0-9]+(?:\.[0-9]{1,2})?$/.test(price) ? Number(price) : NaN
      const line = Math.round(qty * each * 100) / 100
      total += line
      const cell = row.querySelector("[data-line-total]")
      if (cell) cell.textContent = this.money(line)
    })
    this.totalTargets.forEach((element) => {
      element.textContent = this.money(total)
    })
    const party = Number(document.querySelector("input[data-party-size]")?.value || 0)
    guests = party
    this.countTargets.forEach((element) => {
      element.textContent = guests > 0 ? `Total for ${guests} ${guests === 1 ? "guest" : "guests"}` : "Total"
    })
  }

  money(value) {
    if (!Number.isFinite(value)) return "Check price"
    return "$" + value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
