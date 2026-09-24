import { Controller } from "@hotwired/stimulus"

// Toggles the add-project form between "connect an existing repository" and
// "create a new (blank) repository" modes (issue #3954). In create mode it
// also loads the owner options (user login + organizations) for the selected
// credential and keeps the shared hidden fields in sync.
export default class extends Controller {
  static targets = [
    "modeField", "connectTab", "createTab", "connectPane", "createPane",
    "tokenSelect", "installationSelect", "ownerSelect", "repoName",
    "ownerField", "repoField", "githubIdField", "defaultBranchField", "submitButton"
  ]
  static values = { selected: { type: String, default: "connect" } }

  connect() {
    this.applyMode(this.hasSelectedValue && this.selectedValue === "create" ? "create" : "connect", { reloadOwners: false })
  }

  useConnectMode() {
    this.applyMode("connect")
  }

  useCreateMode() {
    this.applyMode("create")
  }

  async credentialChanged() {
    if (this.mode === "create") await this.loadOwners()
  }

  ownerSelected() {
    const option = this.ownerSelectTarget.selectedOptions[0]
    this.ownerFieldTarget.value = option && option.value ? option.value : ""
  }

  repoNameChanged() {
    this.repoFieldTarget.value = this.repoNameTarget.value.trim()
  }

  // Private

  applyMode(mode, { reloadOwners = true } = {}) {
    this.mode = mode
    this.modeFieldTarget.value = mode

    const isCreate = mode === "create"
    this.connectPaneTarget.classList.toggle("hidden", isCreate)
    this.createPaneTarget.classList.toggle("hidden", !isCreate)
    this.styleTab(this.connectTabTarget, !isCreate)
    this.styleTab(this.createTabTarget, isCreate)
    this.submitButtonTarget.value = isCreate ? "Create Project" : "Add Project"

    if (isCreate) {
      // Drop any repository metadata picked in connect mode so the create
      // submission is not polluted with stale github_id/default_branch.
      this.githubIdFieldTarget.value = ""
      this.defaultBranchFieldTarget.value = ""
      this.syncCreateFields()
      if (reloadOwners) this.loadOwners()
    } else {
      this.ownerFieldTarget.value = ""
      this.repoFieldTarget.value = ""
      this.repoNameTarget.value = ""
      this.resyncRepositorySelection()
    }
  }

  syncCreateFields() {
    this.ownerSelected()
    this.repoNameChanged()
  }

  // After switching back to connect mode, re-fire the repository select's
  // change handler so the hidden fields match the (still-selected) option.
  resyncRepositorySelection() {
    const repoSelect = this.element.querySelector('[data-repository-selector-target="repoSelect"]')
    if (repoSelect && repoSelect.value) {
      repoSelect.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  async loadOwners() {
    const credential = this.selectedCredential()
    this.clearOwnerSelect(credential ? "Loading owners..." : "Select a token or installation first...")
    this.ownerSelectTarget.disabled = true
    if (!credential) return

    try {
      const owners = await this.fetchOwners(credential)
      this.populateOwnerSelect(owners)
    } catch (error) {
      console.error("Failed to load owners:", error)
      this.clearOwnerSelect(`Failed to load owners (${credential.type}). Please try again.`)
    } finally {
      this.ownerSelectTarget.disabled = false
    }
  }

  async fetchOwners(credential) {
    if (credential.type === "installation") {
      const login = credential.option.dataset.accountLogin
      return login ? [{ login: login, type: "user" }] : []
    }

    const response = await fetch(`/github_tokens/${credential.id}/owners`, {
      headers: {
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      }
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)

    return await response.json()
  }

  populateOwnerSelect(owners) {
    this.clearOwnerSelect(owners.length ? "Select an owner..." : "No owners available for this credential")

    owners.forEach((owner) => {
      const option = document.createElement("option")
      option.value = owner.login
      option.textContent = owner.type === "organization" ? `${owner.login} (organization)` : owner.login
      this.ownerSelectTarget.appendChild(option)
    })
    this.syncCreateFields()
  }

  clearOwnerSelect(placeholder) {
    this.ownerSelectTarget.innerHTML = ""
    const prompt = document.createElement("option")
    prompt.value = ""
    prompt.textContent = placeholder
    this.ownerSelectTarget.appendChild(prompt)
    this.ownerFieldTarget.value = ""
  }

  selectedCredential() {
    if (this.hasInstallationSelectTarget && this.installationSelectTarget.value !== "") {
      const option = this.installationSelectTarget.selectedOptions[0]
      return { type: "installation", id: this.installationSelectTarget.value, option: option }
    }

    if (this.hasTokenSelectTarget && this.tokenSelectTarget.value !== "") {
      return { type: "token", id: this.tokenSelectTarget.value }
    }

    return null
  }

  styleTab(tab, active) {
    tab.classList.toggle("bg-white", active)
    tab.classList.toggle("shadow-sm", active)
    tab.classList.toggle("text-indigo-600", active)
    tab.classList.toggle("text-gray-700", !active)
  }
}
