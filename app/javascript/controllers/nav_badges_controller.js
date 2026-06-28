import { Controller } from "@hotwired/stimulus"

// Reads badge counts from the notification_nav_badges element and injects
// badge indicators into nav elements. Single sections use data-nav-section;
// dropdown triggers that collapse several sections use data-nav-badge-rollup
// (a space-separated list) to show the combined count of their hidden items.
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
      this.renderBadge(link, counts[link.dataset.navSection] || 0)
    })

    document.querySelectorAll("[data-nav-badge-rollup]").forEach((trigger) => {
      const total = trigger.dataset.navBadgeRollup
        .split(/\s+/)
        .filter(Boolean)
        .reduce((sum, section) => sum + (counts[section] || 0), 0)
      this.renderBadge(trigger, total)
    })
  }

  renderBadge(element, count) {
    const existing = element.querySelector(".nav-badge")
    if (existing) existing.remove()

    if (count > 0) {
      const badge = document.createElement("span")
      badge.className = "nav-badge ml-1 inline-flex items-center justify-center rounded-full bg-red-500 px-1.5 py-0.5 text-[10px] font-bold text-white"
      badge.textContent = count > 99 ? "99+" : count
      element.appendChild(badge)
    }
  }
}
