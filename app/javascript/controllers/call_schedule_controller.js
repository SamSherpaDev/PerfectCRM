import { Controller } from "@hotwired/stimulus"

// Quick-pick helpers and popover positioning for the call-scheduling form (Pacific dates and times).
export default class extends Controller {
  static targets = ["date", "time"]

  connect() {
    this.details = this.element.closest("details.call-schedule-pop")
    this.sheet = this.element.closest(".call-schedule-sheet")
    if (!this.details) return

    this.boundToggle = this.handleToggle.bind(this)
    this.boundOutsideClick = this.handleOutsideClick.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
    this.details.addEventListener("toggle", this.boundToggle)
    if (this.details.open) this.handleToggle()
  }

  disconnect() {
    if (this.details && this.boundToggle) {
      this.details.removeEventListener("toggle", this.boundToggle)
    }
    this.removeDocumentListeners()
  }

  handleToggle() {
    if (!this.details?.open) {
      this.removeDocumentListeners()
      if (this.sheet) this.resetSheetPosition()
      return
    }

    document.querySelectorAll("details.call-schedule-pop[open]").forEach((other) => {
      if (other !== this.details) other.open = false
    })

    this.positionSheet()
    document.addEventListener("click", this.boundOutsideClick)
    document.addEventListener("keydown", this.boundKeydown)
  }

  positionSheet() {
    if (!this.sheet) return

    this.resetSheetPosition()

    if (getComputedStyle(this.sheet).position === "absolute") {
      // Open upward when dropping down would hang past the end of the page,
      // which stretches the document and cuts the sticky rail short.
      const page = this.details.closest("main")
      if (page) {
        const pageRect = page.getBoundingClientRect()
        const sheetHeight = this.sheet.getBoundingClientRect().height
        const roomAbove = this.details.getBoundingClientRect().top - pageRect.top
        if (this.sheet.getBoundingClientRect().bottom > pageRect.bottom && roomAbove >= sheetHeight + 8) {
          this.sheet.style.top = "auto"
          this.sheet.style.bottom = "calc(100% + 8px)"
        }
      }

      const vw = document.documentElement.clientWidth
      const rect = this.sheet.getBoundingClientRect()
      if (rect.right > vw - 16) {
        this.sheet.style.left = "auto"
        this.sheet.style.right = "0"
      }
      if (this.sheet.getBoundingClientRect().left < 16) {
        this.sheet.style.right = "auto"
        this.sheet.style.left = "0"
      }
    }

    const finalRect = this.sheet.getBoundingClientRect()
    const tabbar = document.querySelector(".tabbar")
    const tabbarVisible = tabbar && getComputedStyle(tabbar).display !== "none"
    const bottomLimit = (tabbarVisible ? tabbar.getBoundingClientRect().top : window.innerHeight) - 16
    const header = document.querySelector("header.sticky")
    const headerVisible = header && getComputedStyle(header).display !== "none"
    const topLimit = (headerVisible ? header.getBoundingClientRect().bottom : 0) + 16
    if (finalRect.bottom > bottomLimit) {
      const detailsTop = this.details.getBoundingClientRect().top
      if (finalRect.bottom - detailsTop > bottomLimit - topLimit) {
        // Too tall for the space between the bars: keep the trigger and title
        // below the top bar and scroll inside the form instead.
        this.sheet.style.maxHeight = `${bottomLimit - topLimit - (finalRect.top - detailsTop)}px`
        this.sheet.style.overflowY = "auto"
        window.scrollBy({ top: detailsTop - topLimit, behavior: "instant" })
      } else {
        window.scrollBy({ top: finalRect.bottom - bottomLimit + 12, behavior: "instant" })
      }
    } else if (finalRect.top < topLimit) {
      window.scrollBy({ top: finalRect.top - topLimit, behavior: "instant" })
    }
  }

  resetSheetPosition() {
    this.sheet.style.top = ""
    this.sheet.style.bottom = ""
    this.sheet.style.left = ""
    this.sheet.style.right = ""
    this.sheet.style.maxHeight = ""
    this.sheet.style.overflowY = ""
  }

  handleOutsideClick(event) {
    if (!this.details?.open) return
    if (!this.details.contains(event.target)) {
      this.details.open = false
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.details?.open) {
      this.details.open = false
      this.details.querySelector("summary")?.focus()
    }
  }

  removeDocumentListeners() {
    if (this.boundOutsideClick) document.removeEventListener("click", this.boundOutsideClick)
    if (this.boundKeydown) document.removeEventListener("keydown", this.boundKeydown)
  }

  pickDate(event) {
    event.preventDefault()
    if (!this.hasDateTarget || !event.params.date) return
    this.dateTarget.value = event.params.date
    this.dateTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.dateTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  pickTime(event) {
    event.preventDefault()
    if (!this.hasTimeTarget || !event.params.time) return
    this.timeTarget.value = event.params.time
    this.timeTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.timeTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
