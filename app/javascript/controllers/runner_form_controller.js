import { Controller } from "@hotwired/stimulus"

const DIRECT_OUTBOUND_RUNNER_KEYS = new Set(["opencode", "kilocode", "pi", "omp"])
const DIRECT_OUTBOUND_SERVICE_TYPES = new Set([
  "anthropic",
  "deepseek",
  "inception",
  "minimax",
  "mistral",
  "openai",
  "openrouter",
  "xai",
  "zai",
  "zai_coding",
])
const PI_SERVICE_TYPES = new Set([
  "anthropic",
  "deepseek",
  "google",
  "minimax",
  "mistral",
  "openai",
  "openrouter",
  "xai",
  "zai",
])
const FREE_POLICY_OPTION = "__free_policy__"
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
    "directOutboundApiProviderSelect",
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
    if (!DIRECT_OUTBOUND_RUNNER_KEYS.has(runnerKey)) return

    const serviceType = this.selectedApiServiceType()
    const modelChoice = this.hasModelSelectTarget ? this.modelSelectTarget.value : ""
    const customModelId = this.hasCustomModelInputTarget ? this.customModelInputTarget.value.trim() : ""

    this.setConfigField(runnerKey, "api_provider", this.providerKeyFor(serviceType))
    this.setConfigField(
      runnerKey,
      "model_policy",
      runnerKey === "opencode" && modelChoice === FREE_POLICY_OPTION ? "free" : "specific"
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
    const showModelSettings = isApiKey && DIRECT_OUTBOUND_RUNNER_KEYS.has(runnerKey)
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
    const freePolicySelected = this.modelPolicyFormEnabledValue &&
      DIRECT_OUTBOUND_RUNNER_KEYS.has(runnerKey) &&
      this.hasModelSelectTarget &&
      this.modelSelectTarget.value === FREE_POLICY_OPTION

    this.tierSettingsTargets.forEach((el) => {
      const matchesRunner = el.dataset.tierRunnerKey === runnerKey
      const requiresFreePolicy = el.dataset.modelPolicyState === "free"
      el.hidden = !(matchesRunner && (!requiresFreePolicy || freePolicySelected || el.dataset.tierRunnerKey === "openrouter_free"))
    })

    this.tierSelectTargets.forEach((select) => {
      const container = select.closest("[data-runner-form-target='tierSettings']")
      const visible = container && !container.hidden
      select.disabled = !visible
    })
  }

  refreshApiKeyOptions(runnerKey = this.currentRunnerKey()) {
    if (!this.hasApiKeySelectTarget) return

    const allowedServiceTypes = this.allowedApiServiceTypesFor(runnerKey)
    let selectedOptionVisible = false

    this.apiKeyOptionTargets.forEach((option) => {
      if (option.value === "") {
        option.hidden = false
        return
      }

      const serviceType = option.dataset.apiServiceType || ""
      const visible = allowedServiceTypes ? allowedServiceTypes.has(serviceType) : false
      option.hidden = !visible
      if (visible && option.selected) selectedOptionVisible = true
    })

    if (!selectedOptionVisible) {
      this.apiKeySelectTarget.value = ""
    }
  }

  populateModelOptions(runnerKey, serviceType) {
    const optionMap = parseJson(this.modelOptionsValue, {})
    const options = optionMap[runnerKey]?.[serviceType] || []
    const currentValue = this.currentModelSelectionValue(options)

    this.modelSelectTarget.innerHTML = ""
    this.modelSelectTarget.append(this.buildOption("", "Select a model"))

    const leading = options.filter((option) => option.kind !== "catalog")
    const catalog = options.filter((option) => option.kind === "catalog")

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

  allowedApiServiceTypesFor(runnerKey) {
    if (!runnerKey) return null

    if (runnerKey === "opencode" || runnerKey === "kilocode") return DIRECT_OUTBOUND_SERVICE_TYPES
    if (runnerKey === "pi" || runnerKey === "omp") return PI_SERVICE_TYPES
    if (runnerKey === "openrouter_free" || runnerKey === "openrouter_pareto") return new Set(["openrouter"])

    const staticType = parseJson(
      document.querySelector("meta[name='runner-api-service-type']")?.content,
      {}
    )[runnerKey]
    return staticType ? new Set([staticType]) : null
  }

  runnerApiKeyMode() {
    const selected = this.element.querySelector("input[type='radio'][name*='auth_type']:checked")
    if (selected) return selected.value === "api_key"

    return this.authTypeValue === "api_key"
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
