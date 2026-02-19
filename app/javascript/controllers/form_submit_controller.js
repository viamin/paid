import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["submit"]

  submit() {
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      const label = this.submitTarget.dataset.disableWith || "Saving..."
      if (this.submitTarget.tagName === "INPUT") {
        this.submitTarget.value = label
      } else {
        this.submitTarget.textContent = label
      }
    }
  }
}
