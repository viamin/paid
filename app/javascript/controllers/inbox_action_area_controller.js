import { Controller } from "@hotwired/stimulus"

// Keeps the existing lane-specific controls in one sticky detail-header area.
// Moving the rendered elements (rather than duplicating their markup) retains
// their routes, authorization gates, confirmations, Turbo behavior, and focus.
// @spec OPERATOR-INBOX-028
export default class extends Controller {
  static targets = ["actions", "content"]

  connect() {
    this.collectActions()
  }

  collectActions() {
    const actions = this.contentTarget.querySelectorAll("form, a.inline-flex")
    if (actions.length === 0) return

    actions.forEach((action) => action.classList.add("max-w-full"))
    this.actionsTarget.append(...actions)
    this.actionsTarget.classList.remove("hidden")
  }
}
