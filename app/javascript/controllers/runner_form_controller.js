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
    "policyModelSelect",
    "policyModelManualInput",
    "policyModelPolicyField",
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

    this.refreshTierSettings(runnerKey)
    this.refreshApiKeyOptions(runnerKey)
    this.refreshDynamicModelOptions(runnerKey)
    this.refreshPolicyModelOptions(runnerKey)
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
      // No catalog rows (and no preserved current-model entry) for this
      // provider: fall back to a manual text entry instead of a dead,
      // permanently-disabled select (see LlmModel::CUSTOM_MODEL_OPTION).
      const manualEntry = matches && Boolean(serviceType) && options.length === 0
      const manualInput = this.manualModelInputFor(currentRunnerKey)

      this.replaceDynamicModelOptions(select, options, serviceType)

      const values = options.map((option) => option[1])
      if (values.includes(selectedValue)) {
        select.value = selectedValue
      }

      select.hidden = manualEntry
      select.disabled = !matches || !serviceType || options.length === 0
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

  // RDR-065 (#3669): Runners::ModelOptions-driven select behind
  // runner_model_policy_form. Renders catalog rows grouped by family, an
  // optional Free-policy sentinel, and a trailing "Custom model ID…"
  // sentinel that reveals policyModelManualInput. Coexists with the legacy
  // dynamicModelSelect target above; only one renders per page load, so
  // methods for each no-op harmlessly when their targets are absent.
  refreshPolicyModelOptions(runnerKey = this.currentRunnerKey()) {
    this.policyModelSelectTargets.forEach((select) => {
      const selectRunnerKey = select.dataset.runnerKey
      const matches = selectRunnerKey === runnerKey && this.runnerApiKeyMode()
      const serviceType = this.requiredApiServiceTypeFor(selectRunnerKey)
      const entriesByServiceType = this.modelEntriesByServiceType(select)
      const entries = serviceType ? entriesByServiceType[serviceType] || [] : []
      const selectedValue = select.value

      this.replacePolicyModelOptions(select, entries, serviceType)

      const values = entries.map((entry) => entry.value)
      select.value = values.includes(selectedValue) ? selectedValue : ""

      select.disabled = !matches || !serviceType || entries.length === 0
      select.dataset.currentServiceType = matches ? serviceType || "" : ""

      this.syncPolicyModelField(select)
    })
  }

  modelEntriesByServiceType(select) {
    if (!select?.dataset.modelEntriesByServiceType) return {}

    try {
      const parsed = JSON.parse(select.dataset.modelEntriesByServiceType)
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch {
      return {}
    }
  }

  replacePolicyModelOptions(select, entries, serviceType) {
    const placeholder = !serviceType ? "Select an API key first" :
      select.dataset.optionalModel === "true" ? "Use provider default" : "Select a model"
    select.options.length = 0
    select.add(new Option(placeholder, ""))

    entries.filter((entry) => entry.kind === "free_policy").forEach((entry) => {
      select.add(new Option(entry.label, entry.value))
    })

    const families = []
    const entriesByFamily = {}
    entries.filter((entry) => entry.kind === "model").forEach((entry) => {
      const family = entry.family || "Other"
      if (!entriesByFamily[family]) {
        entriesByFamily[family] = []
        families.push(family)
      }
      entriesByFamily[family].push(entry)
    })

    families.forEach((family) => {
      const group = document.createElement("optgroup")
      group.label = family
      entriesByFamily[family].forEach((entry) => {
        group.appendChild(new Option(entry.label, entry.value))
      })
      select.add(group)
    })

    entries.filter((entry) => entry.kind === "custom").forEach((entry) => {
      select.add(new Option(entry.label, entry.value))
    })
  }

  // Only one of {select, manual input} carries the `name` attribute at a
  // time, so the sentinel value ("free"/"custom") itself is never submitted
  // as the model id. The select stays enabled so the user can freely switch
  // back to a catalog row without a page reload.
  // @spec MODEL-POLICY-FORM-003 MODEL-POLICY-FORM-004
  handlePolicyModelChange(event) {
    this.syncPolicyModelField(event.target)
  }

  syncPolicyModelField(select) {
    const runnerKey = select.dataset.runnerKey
    const manualInput = this.policyManualInputFor(runnerKey)
    const policyField = this.policyFieldFor(runnerKey)
    const fieldName = `runner[config][${runnerKey}][model]`
    const isCustom = select.value === "custom"
    const isFree = select.value === "free"

    select.name = isCustom || isFree ? "" : fieldName

    if (manualInput) {
      manualInput.hidden = !isCustom
      manualInput.disabled = !isCustom
      manualInput.name = isCustom ? fieldName : ""
    }

    if (policyField) {
      policyField.value = isFree ? "free" : "specific"
    }
  }

  policyManualInputFor(runnerKey) {
    return (this.policyModelManualInputTargets || []).find((target) => target.dataset.runnerKey === runnerKey)
  }

  policyFieldFor(runnerKey) {
    return (this.policyModelPolicyFieldTargets || []).find((target) => target.dataset.runnerKey === runnerKey)
  }

  modelSelectFor(runnerKey) {
    return (
      this.dynamicModelSelectTargets.find((target) => target.dataset.runnerKey === runnerKey) ||
      this.policyModelSelectTargets.find((target) => target.dataset.runnerKey === runnerKey) ||
      null
    )
  }

  serviceTypesFor(select) {
    if (!select) return new Set()
    if (select.dataset.modelEntriesByServiceType) {
      return new Set(Object.keys(this.modelEntriesByServiceType(select)))
    }

    return new Set(Object.keys(this.modelOptionsByServiceType(select)))
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

      const modelSelect = this.modelSelectFor(runnerKey)
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
    return this.serviceTypesFor(this.modelSelectFor(runnerKey))
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
