import { Controller } from "@hotwired/stimulus"

// Reads provider→service-type mapping from the backend-provided meta tag so that
// ProviderSupport::PROVIDER_API_SERVICE_TYPE remains the single source of truth.
// Falls back to a hardcoded mapping if the meta tag is missing.
function loadProviderApiServiceType() {
  try {
    const meta = document.querySelector("meta[name='provider-api-service-type']")
    if (meta && meta.content) {
      const parsed = JSON.parse(meta.content)
      if (parsed && typeof parsed === "object") return parsed
    }
  } catch {
    // Fall back to the default mapping below.
  }

  return {
    claude: "anthropic",
    cursor: "anthropic",
    codex: "openai",
    aider: "anthropic",
    gemini: "google",
    opencode: "openrouter",
    kilocode: "anthropic",
  }
}

const PROVIDER_API_SERVICE_TYPE = loadProviderApiServiceType()

export default class extends Controller {
  static values = {
    authType: String,
  }

  static targets = [
    "subscriptionFields",
    "apiKeyFields",
    "apiKeySelectContainer",
    "apiKeySelect",
    "fallbackRoleField",
    "providerSelect",
    "apiKeyOption",
    "opencodeSettings",
  ]

  connect() {
    this.toggleAuthType()
  }

  toggleAuthType() {
    const radios = this.element.querySelectorAll("input[type='radio'][name*='auth_type']")
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
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

    this.apiKeySelectContainerTargets.forEach((el) => {
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

    const requiredServiceType = this.requiredApiServiceTypeFor(providerKey)
    let selectedOptionVisible = false

    this.apiKeyOptionTargets.forEach((option) => {
      if (option.value === "") {
        option.hidden = false
        return
      }

      const serviceType = option.dataset.apiServiceType || ""
      // When requiredServiceType is null (unknown/unmapped provider), hide all
      // API key options — the provider has no compatible API key type.
      const visible = requiredServiceType !== null && serviceType === requiredServiceType
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
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    if (selected) return selected.value === "api_key"

    return this.authTypeValue === "api_key"
  }

  requiredApiServiceTypeFor(providerKey) {
    if (!providerKey) return null
    // Returns null for unknown/unmapped providers (e.g. copilot), which causes
    // refreshApiKeyOptions to hide all API key options — the correct behavior
    // since those providers have no compatible API key type.
    return PROVIDER_API_SERVICE_TYPE[providerKey] || null
  }

  currentProviderKey() {
    const visibleSelect = this.providerSelectTargets.find((select) => !select.disabled)
    if (visibleSelect) return visibleSelect.value
    if (this.providerSelectTargets[0]) return this.providerSelectTargets[0].value

    const hiddenField = this.element.querySelector("input[name='provider[provider_key]']")
    return hiddenField?.value || ""
  }
}
