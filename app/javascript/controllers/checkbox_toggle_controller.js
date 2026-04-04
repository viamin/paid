import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "panel"]

  connect() {
    this.toggle()
  }

  toggle() {
    const checked = this.checkboxTarget.checked

    this.panelTargets.forEach((el) => {
      el.hidden = !checked
      el.querySelectorAll("select, input, textarea, button").forEach((control) => {
        control.disabled = !checked
      })
    })
  }
}
