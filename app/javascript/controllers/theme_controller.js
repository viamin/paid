import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { preference: { type: String, default: "system" } }

  connect() {
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.handleSystemChange = this.applyTheme.bind(this)
    this.mediaQuery.addEventListener("change", this.handleSystemChange)
    this.applyTheme()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this.handleSystemChange)
  }

  preferenceValueChanged() {
    this.applyTheme()
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
  }
}
