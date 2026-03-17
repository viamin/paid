import { Controller } from "@hotwired/stimulus"

// Displays a live-updating elapsed time counter for running agent runs.
export default class extends Controller {
  static targets = ["display"]
  static values = { startedAt: String }

  connect() {
    if (this.startedAtValue) {
      this.startTime = new Date(this.startedAtValue)
      this.update()
      this.timer = window.setInterval(() => this.update(), 1000)
    }
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  update() {
    const elapsed = Math.floor((Date.now() - this.startTime.getTime()) / 1000)
    this.displayTarget.textContent = this.formatDuration(elapsed)
  }

  // NOTE: Keep in sync with DashboardHelper#format_duration on the server side.
  formatDuration(seconds) {
    if (seconds >= 86400) {
      const d = Math.floor(seconds / 86400)
      const h = Math.floor((seconds % 86400) / 3600)
      return `${d}d ${h}h`
    } else if (seconds >= 3600) {
      const h = Math.floor(seconds / 3600)
      const m = Math.floor((seconds % 3600) / 60)
      return `${h}h ${m}m`
    } else if (seconds >= 60) {
      const m = Math.floor(seconds / 60)
      const s = seconds % 60
      return `${m}m ${s}s`
    }
    return `${seconds}s`
  }
}
