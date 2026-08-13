import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display"]
  static values = { startedAt: String }

  connect() {
    if (!this.startedAtValue) return

    this.startTime = new Date(this.startedAtValue)
    this.update()
    this.timer = window.setInterval(() => this.update(), 1000)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  update() {
    const elapsed = Math.floor((Date.now() - this.startTime.getTime()) / 1000)
    this.displayTarget.textContent = this.formatDuration(elapsed)
  }

  // Keep in sync with DashboardHelper#format_duration.
  formatDuration(seconds) {
    if (seconds >= 86400) {
      const days = Math.floor(seconds / 86400)
      const hours = Math.floor((seconds % 86400) / 3600)
      return `${days}d ${hours}h`
    }

    if (seconds >= 3600) {
      const hours = Math.floor(seconds / 3600)
      const minutes = Math.floor((seconds % 3600) / 60)
      return `${hours}h ${minutes}m`
    }

    if (seconds >= 60) {
      const minutes = Math.floor(seconds / 60)
      const remainingSeconds = seconds % 60
      return `${minutes}m ${remainingSeconds}s`
    }

    return `${seconds}s`
  }
}
