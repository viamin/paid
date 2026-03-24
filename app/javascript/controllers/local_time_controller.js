import { Controller } from "@hotwired/stimulus"

// Formats <time> elements with UTC datetime attributes into the user's local timezone.
//
// Usage:
//   <time data-controller="local-time" data-local-time-format-value="long"
//         datetime="2024-01-15T12:00:00Z">Jan 15, 2024 12:00 UTC</time>
//
// Supported formats:
//   "long"     → "January 15, 2024 at 3:45 PM EST"
//   "short"    → "Jan 15, 2024 3:45 PM"
//   "date"     → "Jan 15, 2024"
//   "time"     → "3:45:00 PM"
//   "relative" → "2 hours ago" (updates periodically)
export default class extends Controller {
  static values = { format: { type: String, default: "long" } }

  connect() {
    this.formatTime()

    if (this.formatValue === "relative") {
      this.startRefreshing()
    }
  }

  disconnect() {
    this.stopRefreshing()
  }

  formatTime() {
    const datetime = this.element.getAttribute("datetime")
    if (!datetime) return

    const date = new Date(datetime)
    if (isNaN(date.getTime())) return

    this.element.textContent = this.formatDate(date)
    this.element.title = date.toLocaleString()
  }

  formatDate(date) {
    switch (this.formatValue) {
      case "long":
        return date.toLocaleString(undefined, {
          year: "numeric", month: "long", day: "numeric",
          hour: "numeric", minute: "2-digit", timeZoneName: "short"
        })
      case "short":
        return date.toLocaleString(undefined, {
          year: "numeric", month: "short", day: "numeric",
          hour: "numeric", minute: "2-digit"
        })
      case "date":
        return date.toLocaleDateString(undefined, {
          year: "numeric", month: "short", day: "numeric"
        })
      case "time":
        return date.toLocaleTimeString(undefined, {
          hour: "numeric", minute: "2-digit", second: "2-digit"
        })
      case "relative":
        return this.relativeTime(date)
      default:
        return date.toLocaleString()
    }
  }

  relativeTime(date) {
    const now = new Date()
    const diffMs = now - date
    const absDiffMs = Math.abs(diffMs)
    const future = diffMs < 0

    const seconds = Math.floor(absDiffMs / 1000)
    const minutes = Math.floor(seconds / 60)
    const hours = Math.floor(minutes / 60)
    const days = Math.floor(hours / 24)

    let result
    if (seconds < 60) {
      result = "less than a minute"
    } else if (minutes < 60) {
      result = minutes === 1 ? "1 minute" : `${minutes} minutes`
    } else if (hours < 24) {
      result = hours === 1 ? "about 1 hour" : `about ${hours} hours`
    } else {
      result = days === 1 ? "1 day" : `${days} days`
    }

    return future ? `in ${result}` : `${result} ago`
  }

  startRefreshing() {
    this.refreshTimer = window.setInterval(() => this.formatTime(), 60000)
  }

  stopRefreshing() {
    if (this.refreshTimer) {
      window.clearInterval(this.refreshTimer)
    }
  }
}
