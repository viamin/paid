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

const FREE_POLICY_OPTION = "free"
const CUSTOM_OPTION = "custom"

function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch {
    return fallback
  }
}

export default class extends Controller {
  static values = {
    authType: String,
    modelPolicyFormEnabled: Boolean,
    modelOptions: String,
    initialApiServiceType: String,
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
    "modelSettings",
    "modelSelect",
    "customModelField",
    "customModelInput",
    "configField",
    "kilocodePreflightField",
  ]

  connect() {
    this.toggleAuthType()
  }

  // Parsed once and memoized: this.modelOptionsValue is set once by the
  // server and never mutated client-side, and the map can be large (it
  // embeds the full catalog per service type).
  get modelOptionsMap() {
    this._modelOptionsMap ||= parseJson(this.modelOptionsValue, {})
    return this._modelOptionsMap
  }

  // Runner keys with a model dropdown (Runner-side FORM_MODEL_RUNNER_KEYS),
  // derived from the map's own keys so the frontend never hardcodes a list
  // that could drift from the backend constants that built it.
  get directOutboundRunnerKeys() {
    return new Set(Object.keys(this.modelOptionsMap))
  }

  toggleAuthType() {
    const radios = this.element.querySelectorAll("input[type='radio'][name*='auth_type']")
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    const isApiKey = radios.length === 0 ? this.runnerApiKeyMode() : selected?.value === "api_key"

    this.subscriptionFieldsTargets.forEach((el) => {
      el.hidden = isApiKey
      this.toggleControls(el, !isApiKey)
    })

    this.apiKeyFieldsTargets.forEach((el) => {
      el.hidden = !isApiKey
      this.toggleControls(el, isApiKey)
    })

    this.apiKeySelectContainerTargets.forEach((el) => {
      el.hidden = !isApiKey
      this.toggleControls(el, isApiKey)
    })

    this.fallbackRoleFieldTargets.forEach((el) => {
      el.hidden = !isApiKey
      this.toggleControls(el, isApiKey)
    })

    this.refreshRunnerSpecificFields()
  }

  refreshRunnerSpecificFields() {
    const runnerKey = this.currentRunnerKey()
    const isApiKey = this.runnerApiKeyMode()

    this.refreshApiKeyOptions(runnerKey)

    if (this.modelPolicyFormEnabledValue) {
      this.refreshFeatureFlaggedModelForm(runnerKey, isApiKey)
      this.hideLegacySettings()
    } else {
      this.refreshLegacySettings(runnerKey, isApiKey)
      this.refreshDynamicModelOptions(runnerKey)
    }
    this.refreshTierSettings(runnerKey)
  }

  refreshModelState() {
    if (!this.modelPolicyFormEnabledValue) return

    this.toggleCustomModelField(this.hasModelSelectTarget && this.modelSelectTarget.value === CUSTOM_OPTION)
    this.syncModelConfig()
    this.refreshTierSettings(this.currentRunnerKey())
    if (this.hasModelSelectTarget) {
      this.modelSelectTarget.dataset.initialModelSelection = this.modelSelectTarget.value
    }
  }

  syncModelConfig() {
    if (!this.modelPolicyFormEnabledValue) return

    const runnerKey = this.currentRunnerKey()
    if (!this.directOutboundRunnerKeys.has(runnerKey)) return

    const serviceType = this.selectedApiServiceType()
    const modelChoice = this.hasModelSelectTarget ? this.modelSelectTarget.value : ""
    const customModelId = this.hasCustomModelInputTarget ? this.customModelInputTarget.value.trim() : ""

    this.setConfigField(runnerKey, "api_provider", this.providerKeyFor(serviceType))
    this.setConfigField(
      runnerKey,
      "model_policy",
      modelChoice === FREE_POLICY_OPTION ? "free" : "specific"
    )

    if (modelChoice === FREE_POLICY_OPTION) {
      this.setConfigField(runnerKey, "model", "")
    } else if (modelChoice === CUSTOM_OPTION) {
      this.setConfigField(runnerKey, "model", customModelId)
    } else {
      this.setConfigField(runnerKey, "model", modelChoice)
    }
  }

  refreshFeatureFlaggedModelForm(runnerKey, isApiKey) {
    const showModelSettings = isApiKey && this.directOutboundRunnerKeys.has(runnerKey)
    const serviceType = this.selectedApiServiceType()

    this.modelSettingsTargets.forEach((el) => {
      el.hidden = !showModelSettings
    })

    this.kilocodePreflightFieldTargets.forEach((el) => {
      el.hidden = !(showModelSettings && runnerKey === "kilocode")
    })

    this.toggleConfigFields(runnerKey, showModelSettings && Boolean(serviceType))

    if (!showModelSettings || !this.hasModelSelectTarget) {
      this.disableModelControls(true)
      return
    }

    this.populateModelOptions(runnerKey, serviceType)
    this.disableModelControls(!serviceType)
    this.syncModelConfig()
  }

  refreshLegacySettings(runnerKey, isApiKey) {
    this.toggleLegacySection(this.opencodeSettingsTargets, isApiKey && runnerKey === "opencode")
    this.toggleLegacySection(this.kilocodeSettingsTargets, isApiKey && runnerKey === "kilocode")
    this.toggleLegacySection(this.piSettingsTargets, isApiKey && runnerKey === "pi")
    this.toggleLegacySection(this.ompSettingsTargets, isApiKey && runnerKey === "omp")
  }

  hideLegacySettings() {
    this.toggleLegacySection(this.opencodeSettingsTargets, false)
    this.toggleLegacySection(this.kilocodeSettingsTargets, false)
    this.toggleLegacySection(this.piSettingsTargets, false)
    this.toggleLegacySection(this.ompSettingsTargets, false)
  }

  toggleLegacySection(targets, visible) {
    targets.forEach((el) => {
      el.hidden = !visible
      this.toggleControls(el, visible)
    })
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
      if (visible && option.selected) selectedOptionVisible = true
    })

    if (!selectedOptionVisible) {
      this.apiKeySelectTarget.value = ""
    }
  }

  populateModelOptions(runnerKey, serviceType) {
    const options = this.modelOptionsMap[runnerKey]?.[serviceType] || []
    const currentValue = this.currentModelSelectionValue(options)

    this.modelSelectTarget.innerHTML = ""
    this.modelSelectTarget.append(this.buildOption("", "Select a model"))

    const leading = options.filter((option) => option.kind !== "model")
    const catalog = options.filter((option) => option.kind === "model")

    leading.forEach((option) => {
      this.modelSelectTarget.append(this.buildOption(option.value, option.label))
    })

    const groupedCatalog = catalog.reduce((groups, option) => {
      const family = option.family || "Other"
      groups[family] ||= []
      groups[family].push(option)
      return groups
    }, {})

    Object.entries(groupedCatalog).forEach(([family, groupOptions]) => {
      const optgroup = document.createElement("optgroup")
      optgroup.label = family
      groupOptions.forEach((option) => {
        optgroup.append(this.buildOption(option.value, option.label))
      })
      this.modelSelectTarget.append(optgroup)
    })

    this.modelSelectTarget.value = currentValue
    this.toggleCustomModelField(currentValue === CUSTOM_OPTION)
  }

  currentModelSelectionValue(options) {
    const current = this.hasModelSelectTarget ? this.modelSelectTarget.value : ""
    const initial = this.modelSelectTarget.dataset.initialModelSelection || ""
    const values = new Set(options.map((option) => option.value))

    if (values.has(current)) return current
    if (values.has(initial)) return initial
    if (this.hasCustomModelInputTarget && this.customModelInputTarget.value.trim() !== "") return CUSTOM_OPTION

    return ""
  }

  toggleCustomModelField(visible) {
    this.customModelFieldTargets.forEach((el) => {
      el.hidden = !visible
      this.toggleControls(el, visible)
    })

    if (!visible && this.hasCustomModelInputTarget) {
      this.customModelInputTarget.value = ""
    }
  }

  disableModelControls(disabled) {
    if (this.hasModelSelectTarget) this.modelSelectTarget.disabled = disabled

    const showCustom = !disabled && this.hasModelSelectTarget && this.modelSelectTarget.value === CUSTOM_OPTION
    this.toggleCustomModelField(showCustom)
  }

  buildOption(value, label) {
    const option = document.createElement("option")
    option.value = value
    option.textContent = label
    return option
  }

  setConfigField(runnerKey, fieldName, value) {
    const field = this.configFieldTargets.find((input) => {
      return input.dataset.runnerKey === runnerKey && input.dataset.configField === fieldName
    })
    if (field) field.value = value || ""
  }

  toggleConfigFields(activeRunnerKey, enabled) {
    this.configFieldTargets.forEach((field) => {
      field.disabled = !(enabled && field.dataset.runnerKey === activeRunnerKey)
    })
  }

  providerKeyFor(serviceType) {
    return serviceType || ""
  }

  selectedApiServiceType() {
    if (this.hasApiKeySelectTarget) {
      const selected = this.apiKeySelectTarget.selectedOptions[0]
      if (selected?.dataset?.apiServiceType) return selected.dataset.apiServiceType
    }

    return this.initialApiServiceTypeValue || ""
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

    // Flagged path: the exact allowed service types are the keys the server
    // built into modelOptionsValue from the same Ruby constants that define
    // this runner's API providers (supported_service_types_for).
    if (this.modelPolicyFormEnabledValue && this.directOutboundRunnerKeys.has(runnerKey)) {
      return new Set(Object.keys(this.modelOptionsMap[runnerKey] || {})).has(serviceType)
    }

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

    if (this.modelPolicyFormEnabledValue && this.directOutboundRunnerKeys.has(runnerKey)) {
      return this.hasModelSelectTarget && this.modelSelectTarget.value === FREE_POLICY_OPTION
    }

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

  toggleControls(element, enabled) {
    element.querySelectorAll("select, input").forEach((control) => {
      control.disabled = !enabled
    })
  }
}
