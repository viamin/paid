import { Controller } from "@hotwired/stimulus"

// Syncs action-button visibility when Turbo replaces the agent run detail partial.
//
// The detail partial carries data-agent-run-status and data-agent-run-has-error
// on its root element. When a Turbo Stream broadcast replaces that element,
// this controller detects the change via MutationObserver and hides/shows
// action sections accordingly:
//
//   data-when-active       — visible while the run is active (pending/running)
//   data-when-finished     — visible once the run has finished (any terminal status)
//   data-when-auth-expired — visible when the run's status is auth_expired
//   data-when-error        — visible when the run has an error message
const ACTIVE_STATUSES = ["pending", "running"]
const FINISHED_STATUSES = [
  "completed",
  "failed",
  "cancelled",
  "timeout",
  "retried",
  "auth_expired",
  "rate_limited",
]

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
    const authExpired = status === "auth_expired"
    const hasError = detail.dataset.agentRunHasError === "true"

    this.actionsTarget.querySelectorAll("[data-when-active]").forEach((el) => {
      el.hidden = !active
    })
    const finished = FINISHED_STATUSES.includes(status)
    this.actionsTarget.querySelectorAll("[data-when-finished]").forEach((el) => {
      el.hidden = !finished
    })
    this.actionsTarget
      .querySelectorAll("[data-when-auth-expired]")
      .forEach((el) => {
        el.hidden = !authExpired
      })
    this.actionsTarget.querySelectorAll("[data-when-error]").forEach((el) => {
      el.hidden = !hasError
    })
  }
}
