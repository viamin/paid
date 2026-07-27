import { Controller } from "@hotwired/stimulus"

// Reads runner→service-type mapping from the backend-provided meta tag so that
// RunnerSupport::RUNNER_API_SERVICE_TYPE remains the single source of truth.
// Falls back to a hardcoded mapping if the meta tag is missing.
function loadRunnerApiServiceType() {
  try {
    const meta = document.querySelector("meta[name='runner-api-service-type']")
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
    gemini: "google",
    openrouter_free: "openrouter",
    openrouter_pareto: "openrouter",
  }
}

const RUNNER_API_SERVICE_TYPE = loadRunnerApiServiceType()

// OpenCode, KiloCode, and Pi support multiple upstream API providers, each with its
// own API key type. The mapping is derived from data-service-type attributes on
// the <option> elements rendered by the backend (Runner::DIRECT_OUTBOUND_API_PROVIDERS),
// keeping the backend as the single source of truth.
function loadDirectOutboundApiProviderServiceTypes() {
  const selects = document.querySelectorAll(
    "[data-runner-form-target='directOutboundApiProviderSelect']"
  )
  for (const select of selects) {
    const mapping = {}
    let found = false
    for (const option of select.options) {
      const serviceType = option.dataset?.serviceType
      if (option.value && serviceType) {
        mapping[option.value] = serviceType
        found = true
      }
    }
    if (found) return mapping
  }

  // Fallback if backend has not yet rendered the options (e.g. no runner form on page).
  return {}
}

// Runner keys that use dynamic api_provider selection.
const DYNAMIC_API_RUNNER_KEYS = new Set(["opencode", "kilocode", "pi"])

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
    "runnerSelect",
    "apiKeyOption",
    "opencodeSettings",
    "kilocodeSettings",
    "piSettings",
    "directOutboundApiProviderSelect",
    "tierSettings",
    "tierSelect",
  ]

  connect() {
    this.toggleAuthType()
  }

  toggleAuthType() {
    const radios = this.element.querySelectorAll("input[type='radio'][name*='auth_type']")
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    const isApiKey = radios.length === 0 ? this.runnerApiKeyMode() : selected?.value === "api_key"

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

    this.refreshRunnerSpecificFields()
  }

  refreshRunnerSpecificFields() {
    const runnerKey = this.currentRunnerKey()
    const isApiKey = this.runnerApiKeyMode()
    const showOpenCodeSettings = isApiKey && runnerKey === "opencode"
    const showKiloCodeSettings = isApiKey && runnerKey === "kilocode"
    const showPiSettings = isApiKey && runnerKey === "pi"

    this.opencodeSettingsTargets.forEach((el) => {
      el.hidden = !showOpenCodeSettings
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !showOpenCodeSettings
      })
    })

    this.kilocodeSettingsTargets.forEach((el) => {
      el.hidden = !showKiloCodeSettings
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !showKiloCodeSettings
      })
    })

    this.piSettingsTargets.forEach((el) => {
      el.hidden = !showPiSettings
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !showPiSettings
      })
    })

    this.refreshTierSettings(runnerKey)
    this.refreshApiKeyOptions(runnerKey)
  }

  refreshTierSettings(runnerKey = this.currentRunnerKey()) {
    this.tierSettingsTargets.forEach((el) => {
      const renderedFor = el.dataset.tierRunnerKey
      const matches = renderedFor === runnerKey
      el.hidden = !matches
    })

    this.tierSelectTargets.forEach((select) => {
      const container = select.closest("[data-runner-form-target='tierSettings']")
      const matches = container && container.dataset.tierRunnerKey === runnerKey
      select.disabled = !matches
      if (!matches) select.value = ""
    })
  }

  refreshApiKeyOptions(runnerKey = this.currentRunnerKey()) {
    if (!this.hasApiKeySelectTarget) return

    const requiredServiceType = this.requiredApiServiceTypeFor(runnerKey)
    let selectedOptionVisible = false

    this.apiKeyOptionTargets.forEach((option) => {
      if (option.value === "") {
        option.hidden = false
        return
      }

      const serviceType = option.dataset.apiServiceType || ""
      // When requiredServiceType is null (unknown/unmapped runner), hide all
      // API key options — the runner has no compatible API key type.
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

  runnerApiKeyMode() {
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    if (selected) return selected.value === "api_key"

    return this.authTypeValue === "api_key"
  }

  requiredApiServiceTypeFor(runnerKey) {
    if (!runnerKey) return null

    // OpenCode, KiloCode, and Pi determine their required API key type from
    // the selected api_provider dropdown.
    if (DYNAMIC_API_RUNNER_KEYS.has(runnerKey)) {
      const apiProvider = this.currentDirectOutboundApiProvider(runnerKey)
      // Compute at runtime rather than module-load time so that the mapping
      // is correct even when the first page load didn't include the runner form
      // (Turbo navigation doesn't reload JS modules).
      return loadDirectOutboundApiProviderServiceTypes()[apiProvider] || null
    }

    // Returns null for unknown/unmapped runners (e.g. copilot), which causes
    // refreshApiKeyOptions to hide all API key options — the correct behavior
    // since those runners have no compatible API key type.
    return RUNNER_API_SERVICE_TYPE[runnerKey] || null
  }

  currentDirectOutboundApiProvider(runnerKey) {
    const select = this.directOutboundApiProviderSelectTargets.find(
      (el) => el.dataset.runnerKey === runnerKey
    )
    return select?.value || "openrouter"
  }

  currentRunnerKey() {
    const visibleSelect = this.runnerSelectTargets.find((select) => !select.disabled)
    if (visibleSelect) return visibleSelect.value
    if (this.runnerSelectTargets[0]) return this.runnerSelectTargets[0].value

    const hiddenField = this.element.querySelector("input[name='runner[runner_key]']")
    return hiddenField?.value || ""
  }
}
