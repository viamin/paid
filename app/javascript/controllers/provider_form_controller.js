import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "subscriptionFields",
    "apiKeyFields",
    "apiKeySelect",
    "fallbackRoleField",
    "providerSelect",
    "apiKeyOption",
    "opencodeSettings",
  ]

  connect() {
    this.toggleAuthType()
    this.refreshProviderSpecificFields()
  }

  toggleAuthType() {
    const radios = this.element.querySelectorAll("input[name*='auth_type']")
    const selected = this.element.querySelector("input[name*='auth_type']:checked")
    const isApiKey = radios.length === 0 ? this.providerApiKeyMode() : selected?.value === "api_key"

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

    this.refreshProviderSpecificFields()
  }

  refreshProviderSpecificFields() {
    const providerKey = this.currentProviderKey()
    const isApiKey = this.providerApiKeyMode()
    const showOpenCodeSettings = isApiKey && providerKey === "opencode"

    this.opencodeSettingsTargets.forEach((el) => {
      el.hidden = !showOpenCodeSettings
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !showOpenCodeSettings
      })
    })

    this.refreshApiKeyOptions(providerKey)
  }

  refreshApiKeyOptions(providerKey = this.currentProviderKey()) {
    if (!this.hasApiKeySelectTarget) return

    let selectedOptionVisible = false

    this.apiKeyOptionTargets.forEach((option) => {
      if (option.value === "") {
        option.hidden = false
        return
      }

      const targets = (option.dataset.compatibleTargets || "").split(",").filter(Boolean)
      const visible = providerKey ? targets.includes(providerKey) : true
      option.hidden = !visible
      if (visible && option.selected) {
        selectedOptionVisible = true
      }
    })

    if (!selectedOptionVisible) {
      this.apiKeySelectTarget.value = ""
    }
  }

  providerApiKeyMode() {
    const selected = this.element.querySelector("input[name*='auth_type']:checked")
    if (selected) return selected.value === "api_key"

    const field = this.element.querySelector("input[name='provider[auth_type]']")
    return field?.value === "api_key"
  }

  currentProviderKey() {
    const visibleSelect = this.providerSelectTargets.find((select) => !select.disabled)
    if (visibleSelect) return visibleSelect.value
    if (this.providerSelectTargets[0]) return this.providerSelectTargets[0].value

    const hiddenField = this.element.querySelector("input[name='provider[provider_key]']")
    return hiddenField?.value || ""
  }
}
