import { Controller } from "@hotwired/stimulus"

// Auto-refreshes the shadow-evaluation screen while reviewer execution is
// queued or running (#4642). The server stops rendering this controller as
// soon as execution reaches a terminal state, so the timer disappears with
// the refreshed markup.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = window.setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    window.clearInterval(this.timer)
  }

  refresh() {
    if (document.visibilityState === "hidden") return

    window.location.reload()
  }
}
