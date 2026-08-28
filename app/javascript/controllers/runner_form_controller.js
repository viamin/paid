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

// Runner keys that use dynamic api_provider selection.
const DYNAMIC_API_RUNNER_KEYS = new Set(["opencode", "kilocode", "pi", "omp"])

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
    "ompSettings",
    "dynamicModelSelect",
    "dynamicModelManualInput",
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
    const showOmpSettings = isApiKey && runnerKey === "omp"

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

    this.ompSettingsTargets.forEach((el) => {
      el.hidden = !showOmpSettings
      el.querySelectorAll("select, input").forEach((control) => {
        control.disabled = !showOmpSettings
      })
    })

    this.refreshApiKeyOptions(runnerKey)
    this.refreshDynamicModelOptions(runnerKey)
    this.refreshTierSettings(runnerKey)
  }

  refreshTierSettings(runnerKey = this.currentRunnerKey()) {
    this.tierSettingsTargets.forEach((el) => {
      const renderedFor = el.dataset.tierRunnerKey
      const matches = renderedFor === runnerKey
      const requiresFreePolicy = el.dataset.tierVisibility === "free_policy"
      el.hidden = !matches || (requiresFreePolicy && !this.freePolicySelectedFor(runnerKey))
    })

    this.tierSelectTargets.forEach((select) => {
      const container = select.closest("[data-runner-form-target='tierSettings']")
      const matches = container && !container.hidden
      select.disabled = !matches
      if (!matches) select.value = ""
    })
  }

  refreshApiKeyOptions(runnerKey = this.currentRunnerKey()) {
    if (!this.hasApiKeySelectTarget) return
    let selectedOptionVisible = false

    this.apiKeyOptionTargets.forEach((option) => {
      if (option.value === "") {
        option.hidden = false
        return
      }

      const serviceType = option.dataset.apiServiceType || ""
      const visible = this.apiKeyVisibleForRunner(runnerKey, serviceType)
      option.hidden = !visible
      if (visible && option.selected) {
        selectedOptionVisible = true
      }
    })

    if (!selectedOptionVisible) {
      this.apiKeySelectTarget.value = ""
    }
  }

  refreshDynamicModelOptions(runnerKey = this.currentRunnerKey()) {
    this.dynamicModelSelectTargets.forEach((select) => {
      const currentRunnerKey = select.dataset.runnerKey
      const matches = currentRunnerKey === runnerKey && this.runnerApiKeyMode()
      const serviceType = this.requiredApiServiceTypeFor(currentRunnerKey)
      const optionsByServiceType = this.modelOptionsByServiceType(select)
      const options = serviceType ? optionsByServiceType[serviceType] || [] : []
      const selectedValue = select.value
      const manualInput = this.manualModelInputFor(currentRunnerKey)
      const customValue = select.dataset.customModelValue || ""

      this.replaceDynamicModelOptions(select, options, serviceType)

      const values = options.map((option) => option[1])
      if (values.includes(selectedValue)) {
        select.value = selectedValue
      }
      if (!select.value && values.length === 1 && values[0] === customValue) {
        select.value = customValue
      }

      const manualEntry = matches && Boolean(serviceType) && select.value === customValue

      select.hidden = manualEntry
      select.disabled = !matches || !serviceType || options.length === 0 || manualEntry
      select.dataset.currentServiceType = matches ? serviceType || "" : ""

      if (manualInput) {
        manualInput.hidden = !manualEntry
        manualInput.disabled = !manualEntry
      }
    })
  }

  manualModelInputFor(runnerKey) {
    return (this.dynamicModelManualInputTargets || []).find((target) => target.dataset.runnerKey === runnerKey)
  }

  runnerApiKeyMode() {
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    if (selected) return selected.value === "api_key"

    return this.authTypeValue === "api_key"
  }

  requiredApiServiceTypeFor(runnerKey) {
    if (!runnerKey) return null

    // OpenCode, KiloCode, Pi, and Oh My Pi derive their effective provider from
    // the selected API key's service type.
    if (DYNAMIC_API_RUNNER_KEYS.has(runnerKey)) {
      const selectedApiKey = this.selectedApiKeyOption()
      if (selectedApiKey?.dataset.apiServiceType) return selectedApiKey.dataset.apiServiceType

      const modelSelect = this.dynamicModelSelectTargets.find(
        (target) => target.dataset.runnerKey === runnerKey
      )
      const cachedServiceType = modelSelect?.dataset.currentServiceType
      if (this.dynamicServiceTypesFor(runnerKey).has(cachedServiceType)) {
        return cachedServiceType
      }

      return null
    }

    // Returns null for unknown/unmapped runners (e.g. copilot), which causes
    // refreshApiKeyOptions to hide all API key options — the correct behavior
    // since those runners have no compatible API key type.
    return RUNNER_API_SERVICE_TYPE[runnerKey] || null
  }

  apiKeyVisibleForRunner(runnerKey, serviceType) {
    if (!runnerKey) return false
    if (DYNAMIC_API_RUNNER_KEYS.has(runnerKey)) {
      return this.dynamicServiceTypesFor(runnerKey).has(serviceType)
    }

    const requiredServiceType = this.requiredApiServiceTypeFor(runnerKey)
    return requiredServiceType !== null && serviceType === requiredServiceType
  }

  dynamicServiceTypesFor(runnerKey) {
    const select = this.dynamicModelSelectTargets.find((target) => target.dataset.runnerKey === runnerKey)
    return new Set(Object.keys(this.modelOptionsByServiceType(select)))
  }

  modelOptionsByServiceType(select) {
    if (!select?.dataset.modelOptionsByServiceType) return {}

    try {
      const parsed = JSON.parse(select.dataset.modelOptionsByServiceType)
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch {
      return {}
    }
  }

  replaceDynamicModelOptions(select, options, serviceType) {
    const placeholder = !serviceType ? "Select an API key first" :
      select.dataset.optionalModel === "true" ? "Use provider default" : "Select a model"
    select.options.length = 0
    select.add(new Option(placeholder, ""))

    options.forEach(([label, value]) => {
      select.add(new Option(label, value))
    })
  }

  freePolicySelectedFor(runnerKey) {
    if (runnerKey === "openrouter_free") return true

    const select = this.dynamicModelSelectTargets.find((target) => target.dataset.runnerKey === runnerKey)
    if (!select) return false

    return select.value === (select.dataset.freePolicyValue || "")
  }

  selectedApiKeyOption() {
    if (!this.hasApiKeySelectTarget) return null

    return this.apiKeySelectTarget.selectedOptions[0] || null
  }

  currentRunnerKey() {
    const visibleSelect = this.runnerSelectTargets.find((select) => !select.disabled)
    if (visibleSelect) return visibleSelect.value
    if (this.runnerSelectTargets[0]) return this.runnerSelectTargets[0].value

    const hiddenField = this.element.querySelector("input[name='runner[runner_key]']")
    return hiddenField?.value || ""
  }
}
