import { Controller } from "@hotwired/stimulus"

// The Inbox filter form is server-backed. This controller only owns dialog
// focus and lifecycle; it never filters option or search data in the browser.
// @spec INBOX-FOUNDATION-012
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
