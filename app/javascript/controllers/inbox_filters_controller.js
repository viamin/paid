import { Controller } from "@hotwired/stimulus"

// @spec INBOX-FOUNDATION-009
export default class extends Controller {
  static targets = ["dialog", "projectOption", "projectSearch", "trigger"]

  open() {
    this.dialogTarget.showModal()
    this.projectSearchTarget.focus()
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

  filterProjects() {
    const query = this.projectSearchTarget.value.trim().toLowerCase()

    this.projectOptionTargets.forEach((option) => {
      option.hidden = query.length > 0 && !option.dataset.projectName?.includes(query)
    })
  }
}
