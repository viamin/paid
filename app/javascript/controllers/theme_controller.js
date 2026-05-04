import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { preference: { type: String, default: "system" } }
  static targets = ["icon"]

  initialize() {
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.handleSystemChange = this.applyTheme.bind(this)
  }

  connect() {
    this.mediaQuery.addEventListener("change", this.handleSystemChange)
    this.applyTheme()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.handleSystemChange)
  }

  preferenceValueChanged() {
    this.applyTheme()
  }

  toggle() {
    const cycle = ["light", "dark", "system"]
    const current = this.preferenceValue
    const next = cycle[(cycle.indexOf(current) + 1) % cycle.length]
    this.preferenceValue = next
  }

  applyTheme() {
    const preference = this.preferenceValue
    let dark = false

    if (preference === "dark") {
      dark = true
    } else if (preference === "system") {
      dark = this.mediaQuery.matches
    }

    document.documentElement.classList.toggle("dark", dark)
    window.localStorage.setItem("theme_preference", preference)
    this.updateIcons(preference, dark)
  }

  updateIcons(preference, dark) {
    if (!this.hasIconTarget) return

    const label = preference === "system" ? (dark ? "System (dark)" : "System (light)") : preference.charAt(0).toUpperCase() + preference.slice(1)
    this.iconTargets.forEach((icon) => {
      icon.setAttribute("aria-label", `Theme: ${label}`)
      icon.setAttribute("title", `Theme: ${label}. Click to cycle.`)

      const sun = icon.querySelector("[data-icon=sun]")
      const moon = icon.querySelector("[data-icon=moon]")
      const system = icon.querySelector("[data-icon=system]")
      if (sun) sun.classList.toggle("hidden", preference !== "light")
      if (moon) moon.classList.toggle("hidden", preference !== "dark")
      if (system) system.classList.toggle("hidden", preference !== "system")
    })
  }
}
