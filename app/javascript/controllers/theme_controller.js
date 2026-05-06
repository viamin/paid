import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    preference: { type: String, default: "system" },
    signedIn: { type: Boolean, default: false }
  }
  static targets = ["icon"]

  initialize() {
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.handleSystemChange = this.applyTheme.bind(this)
    this._lastPersisted = this.preferenceValue
  }

  connect() {
    if (!this.signedInValue) {
      const stored = this.storedPreference()

      if (stored && stored !== this.preferenceValue) {
        this.preferenceValue = stored // triggers preferenceValueChanged -> applyTheme
        this.mediaQuery.addEventListener("change", this.handleSystemChange)
        return
      }
    }

    this.applyTheme()
    this.mediaQuery.addEventListener("change", this.handleSystemChange)
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

    this.syncSettingsFormSelect(preference)

    if (this.signedInValue && this._lastPersisted !== preference) {
      this.persistToServer(preference)
    }
    this.updateIcons(preference, dark)
  }

  async persistToServer(preference) {
    if (this._persistingPreference === preference) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    if (!csrfToken) return

    this._persistingPreference = preference

    try {
      const response = await fetch("/user_settings.json", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          Accept: "application/json"
        },
        body: JSON.stringify({ user_setting: { theme_preference: preference } })
      })

      if (!response.ok) throw new Error(`Theme update failed with status ${response.status}`)

      this._lastPersisted = preference
    } catch {
      // Keep the UI preference locally and allow a later applyTheme cycle to retry
      // the server update if the persisted value is still stale.
    } finally {
      if (this._persistingPreference === preference) {
        this._persistingPreference = null
      }

      if (
        this.signedInValue &&
        this.preferenceValue !== preference &&
        this._lastPersisted !== this.preferenceValue
      ) {
        this.persistToServer(this.preferenceValue)
      }
    }
  }

  updateIcons(preference, dark) {
    if (!this.hasIconTarget) return

    const label = preference === "system" ? (dark ? "System (dark)" : "System (light)") : preference.charAt(0).toUpperCase() + preference.slice(1)
    document.documentElement.dataset.themeEffectivePreference = preference

    this.iconTargets.forEach((icon) => {
      icon.setAttribute("aria-label", `Cycle theme (current: ${label})`)
      icon.setAttribute("title", `Cycle theme. Current: ${label}.`)

      const sun = icon.querySelector("[data-theme-icon=sun]")
      const moon = icon.querySelector("[data-theme-icon=moon]")
      const system = icon.querySelector("[data-theme-icon=system]")
      if (sun) sun.classList.toggle("hidden", preference !== "light")
      if (moon) moon.classList.toggle("hidden", preference !== "dark")
      if (system) system.classList.toggle("hidden", preference !== "system")
    })
  }

  syncSettingsFormSelect(preference) {
    const select = document.getElementById("user_setting_theme_preference")
    if (select && select.value !== preference) {
      select.value = preference
    }
  }

  storedPreference() {
    const stored = window.localStorage.getItem("theme_preference")

    return ["light", "dark", "system"].includes(stored) ? stored : null
  }
}
