import { Controller } from "@hotwired/stimulus"

// Reads badge counts from the notification_nav_badges element and injects
// badge indicators into nav links that have a matching data-nav-section attribute.
export default class extends Controller {
  static values = { counts: Object }

  countsValueChanged() {
    this.updateBadges()
  }

  connect() {
    this.updateBadges()
  }

  updateBadges() {
    const counts = this.countsValue
    document.querySelectorAll("[data-nav-section]").forEach((link) => {
      const section = link.dataset.navSection
      const existing = link.querySelector(".nav-badge")
      if (existing) existing.remove()

      const count = counts[section]
      if (count && count > 0) {
        const badge = document.createElement("span")
        badge.className = "nav-badge ml-1 inline-flex items-center justify-center rounded-full bg-red-500 px-1.5 py-0.5 text-[10px] font-bold text-white"
        badge.textContent = count > 99 ? "99+" : count
        link.appendChild(badge)
      }
    })
  }
}
