import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "subscriptionFields",
    "apiKeyFields",
    "apiKeySelect",
    "fallbackRoleField",
  ]

  connect() {
    this.toggleAuthType()
  }

  toggleAuthType() {
    const radios = this.element.querySelectorAll("input[name*='auth_type']")

    // On edit, auth_type radios are not rendered — leave server-rendered
    // state alone so persisted API-key providers keep their fields visible.
    if (radios.length === 0) return

    const selected = this.element.querySelector(
      "input[name*='auth_type']:checked"
    )
    const isApiKey = selected && selected.value === "api_key"

    this.subscriptionFieldsTargets.forEach((el) => {
      el.hidden = isApiKey
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = isApiKey
      })
    })

    this.apiKeyFieldsTargets.forEach((el) => {
      el.hidden = !isApiKey
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !isApiKey
      })
    })

    this.apiKeySelectTargets.forEach((el) => {
      el.hidden = !isApiKey
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !isApiKey
      })
    })

    this.fallbackRoleFieldTargets.forEach((el) => {
      el.hidden = !isApiKey
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !isApiKey
      })
    })
  }
}
