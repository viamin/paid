import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "button"]
  static values = { name: String }

  connect() {
    this.buttonTarget.disabled = true
    this.validate()
  }

  validate() {
    const matches = this.inputTarget.value === this.nameValue
    this.buttonTarget.disabled = !matches
  }
}
