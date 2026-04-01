import { Controller } from "@hotwired/stimulus"

// Syncs action-button visibility when Turbo replaces the agent run detail partial.
//
// The detail partial carries data-agent-run-status on its root element.
// When a Turbo Stream broadcast replaces that element, this controller
// detects the change via MutationObserver and hides/shows the cancel
// and finished-state action sections accordingly.
const ACTIVE_STATUSES = ["pending", "running"]

export default class extends Controller {
  static targets = ["actions"]
  static values = { detailId: String }

  connect() {
    this.sync()
    this.boundSync = this.sync.bind(this)
    const detail = document.getElementById(this.detailIdValue)
    if (detail && detail.parentNode) {
      this.observer = new window.MutationObserver(this.boundSync)
      this.observer.observe(detail.parentNode, { childList: true })
    }
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }

  sync() {
    const detail = document.getElementById(this.detailIdValue)
    if (!detail) {
      return
    }

    const status = detail.dataset.agentRunStatus
    if (!status) {
      return
    }

    const active = ACTIVE_STATUSES.includes(status)

    this.actionsTarget.querySelectorAll("[data-when-active]").forEach((el) => {
      el.hidden = !active
    })
    this.actionsTarget.querySelectorAll("[data-when-finished]").forEach((el) => {
      el.hidden = active
    })
  }
}
