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
