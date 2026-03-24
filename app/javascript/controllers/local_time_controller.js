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
//   "time"     → "15:45:00"
//   "relative" → "2 hours ago" (updates periodically)

// Shared timer for all relative-format instances to avoid per-element setInterval overhead.
const relativeInstances = new Set()
let sharedTimer = null

function startSharedTimer() {
  if (sharedTimer) return
  sharedTimer = window.setInterval(() => {
    relativeInstances.forEach((instance) => instance.formatTime())
  }, 60000)
}

function stopSharedTimer() {
  if (relativeInstances.size === 0 && sharedTimer) {
    window.clearInterval(sharedTimer)
    sharedTimer = null
  }
}

export default class extends Controller {
  static values = { format: { type: String, default: "long" } }

  connect() {
    this.formatTime()

    if (this.formatValue === "relative") {
      relativeInstances.add(this)
      startSharedTimer()
    }
  }

  disconnect() {
    relativeInstances.delete(this)
    stopSharedTimer()
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
          hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false
        })
      case "relative":
        return this.relativeTime(date)
      default:
        return date.toLocaleString()
    }
  }

  relativeTime(date) {
    const now = new Date()
    const diffMs = date.getTime() - now.getTime()
    const diffSeconds = Math.round(diffMs / 1000)
    if (!this._rtf) {
      this._rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
    }

    const absSeconds = Math.abs(diffSeconds)
    if (absSeconds < 60) {
      return this._rtf.format(0, "minute")
    }

    const diffMinutes = Math.round(diffSeconds / 60)
    if (Math.abs(diffMinutes) < 60) {
      return this._rtf.format(diffMinutes, "minute")
    }

    const diffHours = Math.round(diffMinutes / 60)
    if (Math.abs(diffHours) < 24) {
      return this._rtf.format(diffHours, "hour")
    }

    const diffDays = Math.round(diffHours / 24)
    return this._rtf.format(diffDays, "day")
  }

}
