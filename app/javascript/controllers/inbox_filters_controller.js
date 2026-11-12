import { Controller } from "@hotwired/stimulus"

// @spec INBOX-FOUNDATION-009 OPERATOR-INBOX-028
export default class extends Controller {
  static targets = ["dialog", "trigger"]

  open() {
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  closed() {
    this.triggerTarget.focus()
  }

  apply() {
    this.close()
  }
}
