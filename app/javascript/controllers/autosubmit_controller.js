import { Controller } from "@hotwired/stimulus"

// Native form submission without inline JavaScript, including the template
// refill button whose name/value tells the server to re-render the preview.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }

  refill() {
    this.element.requestSubmit(this.element.querySelector("[name=refill]"))
  }
}
