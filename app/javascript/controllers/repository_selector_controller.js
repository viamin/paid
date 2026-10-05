import { Controller } from "@hotwired/stimulus"

// @spec PROJECT-CREATION-013 PROJECT-CREATION-014
export default class extends Controller {
  static targets = ["tokenSelect", "installationSelect", "repoSelect", "repoList", "repoClear", "repoStatus", "sortSelect", "owner", "repo", "githubId", "defaultBranch", "loading"]
  static values = { selectedRepository: String }

  connect() {
    this.repositories = []
    this.filteredRepositories = []
    this.activeIndex = -1
    this.loading = false
    this.updateRepoDisabledState()
    this.updateRepoClearState()
    this.updateSortDisabledState()
    this.loadRepositoriesFromSelection()
  }

  async tokenChanged() {
    this.clearOtherCredential("token")
    await this.loadRepositoriesFromSelection()
  }

  async installationChanged() {
    this.clearOtherCredential("installation")
    await this.loadRepositoriesFromSelection()
  }

  inputChanged() {
    this.clearHiddenFields()
    this.filteredRepositories = this.matchingRepositories()
    this.activeIndex = this.filteredRepositories.length ? 0 : -1
    this.renderRepoList()
    this.openRepoList()
    this.updateRepoClearState()
  }

  repoKeydown(event) {
    if (event.key === "ArrowDown") this.moveActiveOption(event, 1)
    if (event.key === "ArrowUp") this.moveActiveOption(event, -1)
    if (event.key === "Enter") this.selectActiveOption(event)
    if (event.key === "Escape") this.clearWithEscape(event)
  }

  repoSelected() {
    const repository = this.repositories.find((repo) => repo.full_name === this.repoSelectTarget.value)
    if (repository) this.syncRepositoryFields(repository)
    else this.clearHiddenFields()
  }

  repoOptionSelected(event) {
    this.selectRepository(this.filteredRepositories[event.currentTarget.dataset.repositoryIndex])
  }

  clearRepository() {
    this.repoSelectTarget.value = ""
    this.clearHiddenFields()
    this.filteredRepositories = this.sortedRepositories()
    this.activeIndex = -1
    this.renderRepoList()
    this.closeRepoList()
    this.updateRepoClearState()
    this.repoSelectTarget.focus()
  }

  // @spec PROJECT-CREATION-013
  sortChanged() {
    this.filteredRepositories = this.matchingRepositories()
    this.activeIndex = this.filteredRepositories.length ? 0 : -1
    this.renderRepoList()
  }

  // Private

  async loadRepositoriesFromSelection() {
    const selection = this.selectedCredential()
    this.clearRepoSelect()
    this.updateRepoDisabledState()
    this.updateSortDisabledState()
    if (!selection) return

    this.showLoading()

    try {
      const response = await fetch(selection.path, {
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        }
      })

      if (!response.ok) {
        console.error("Failed to load repositories:", { status: response.status, statusText: response.statusText })
        this.showError(this.repositoryLoadError(selection.type, response.status))
        return
      }

      this.populateRepoSelect(await response.json())
    } catch (error) {
      console.error("Unexpected error loading repositories:", error)
      this.showError("Failed to load repositories. Please check your connection and try again.")
    } finally {
      this.hideLoading()
      this.updateRepoDisabledState()
      this.updateSortDisabledState()
    }
  }

  selectedCredential() {
    if (this.hasInstallationSelectTarget && this.installationSelectTarget.value !== "") {
      return { type: "installation", path: `/github_installations/${this.installationSelectTarget.value}/repositories` }
    }

    if (this.hasTokenSelectTarget && this.tokenSelectTarget.value !== "") {
      return { type: "token", path: `/github_tokens/${this.tokenSelectTarget.value}/repositories` }
    }

    return null
  }

  populateRepoSelect(repos) {
    this.repositories = repos
    this.filteredRepositories = this.sortedRepositories()
    this.activeIndex = -1
    this.repoSelectTarget.placeholder = `Search ${repos.length} repositories...`
    this.updateSortDisabledState()
    this.setRepoStatus(`${repos.length} repositories available.`)

    const selectedRepository = this.repositories.find((repo) => repo.full_name === this.selectedRepositoryValue)
    if (this.hasSelectedRepositoryValue && selectedRepository) this.selectRepository(selectedRepository)
    else this.renderRepoList()
  }

  matchingRepositories() {
    const query = this.repoSelectTarget.value.trim().toLocaleLowerCase()
    if (!query) return this.sortedRepositories()

    return this.sortedRepositories().filter((repo) => [repo.full_name, repo.owner, repo.name]
      .some((value) => value.toLocaleLowerCase().includes(query)))
  }

  sortedRepositories() {
    return this.repositories.slice().sort((left, right) => {
      if (this.sortSelectTarget.value === "recent") return this.recentlyCreatedComparator(left, right)

      return left.full_name.localeCompare(right.full_name)
    })
  }

  recentlyCreatedComparator(left, right) {
    const leftCreatedAt = this.createdAt(left)
    const rightCreatedAt = this.createdAt(right)

    if (leftCreatedAt === null && rightCreatedAt === null) return left.full_name.localeCompare(right.full_name)
    if (leftCreatedAt === null) return 1
    if (rightCreatedAt === null) return -1

    return rightCreatedAt - leftCreatedAt || left.full_name.localeCompare(right.full_name)
  }

  createdAt(repository) {
    const timestamp = Date.parse(repository.created_at)
    return Number.isNaN(timestamp) ? null : timestamp
  }

  moveActiveOption(event, direction) {
    event.preventDefault()
    if (!this.filteredRepositories.length) return

    this.openRepoList()
    this.activeIndex = (this.activeIndex + direction + this.filteredRepositories.length) % this.filteredRepositories.length
    this.renderRepoList()
  }

  selectActiveOption(event) {
    if (this.activeIndex < 0) return

    event.preventDefault()
    this.selectRepository(this.filteredRepositories[this.activeIndex])
  }

  clearWithEscape(event) {
    event.preventDefault()
    this.clearRepository()
  }

  selectRepository(repository) {
    if (!repository) return

    this.repoSelectTarget.value = repository.full_name
    this.syncRepositoryFields(repository)
    this.filteredRepositories = this.sortedRepositories()
    this.activeIndex = -1
    this.renderRepoList()
    this.closeRepoList()
    this.updateRepoClearState()
  }

  syncRepositoryFields(repository) {
    this.ownerTarget.value = repository.owner
    this.repoTarget.value = repository.name
    this.githubIdTarget.value = repository.id
    this.defaultBranchTarget.value = repository.default_branch
  }

  clearRepoSelect() {
    const selection = this.selectedCredential()
    this.repositories = []
    this.filteredRepositories = []
    this.activeIndex = -1
    this.repoSelectTarget.value = ""
    this.repoSelectTarget.placeholder = selection ? "Search repositories..." : "Select a token or installation first..."
    this.clearHiddenFields()
    this.clearRepoStatus()
    this.renderRepoList()
    this.closeRepoList()
    this.updateRepoClearState()
  }

  clearHiddenFields() {
    this.ownerTarget.value = ""
    this.repoTarget.value = ""
    this.githubIdTarget.value = ""
    this.defaultBranchTarget.value = ""
  }

  showLoading() {
    this.loading = true
    this.setRepoStatus("Loading repositories...")
    if (this.hasLoadingTarget) this.loadingTarget.classList.remove("hidden")
    this.updateRepoDisabledState()
  }

  hideLoading() {
    this.loading = false
    if (this.hasLoadingTarget) this.loadingTarget.classList.add("hidden")
  }

  showError(message) {
    this.repositories = []
    this.filteredRepositories = []
    this.setRepoStatus(message)
    this.renderRepoList()
  }

  repositoryLoadError(type, status) {
    if (status === 401 || status === 403) return `Unable to load repositories: ${type} is invalid or lacks permissions.`

    return `Failed to load repositories (HTTP ${status}). Please try again.`
  }

  setRepoStatus(message) {
    if (!this.hasRepoStatusTarget) return

    this.repoStatusTarget.textContent = message
    this.repoStatusTarget.classList.remove("hidden")
  }

  clearRepoStatus() {
    if (!this.hasRepoStatusTarget) return

    this.repoStatusTarget.textContent = ""
    this.repoStatusTarget.classList.add("hidden")
  }

  renderRepoList() {
    this.repoListTarget.replaceChildren()
    if (!this.filteredRepositories.length && this.repositories.length) this.renderEmptyResults()
    else this.filteredRepositories.forEach((repository, index) => this.renderRepositoryOption(repository, index))

    this.repoSelectTarget.setAttribute("aria-activedescendant", this.activeIndex >= 0 ? this.optionId(this.activeIndex) : "")
  }

  renderEmptyResults() {
    const message = document.createElement("li")
    message.className = "px-3 py-2 text-sm text-gray-500"
    message.textContent = "No repositories match your search."
    this.repoListTarget.appendChild(message)
  }

  renderRepositoryOption(repository, index) {
    const option = document.createElement("button")
    option.type = "button"
    option.id = this.optionId(index)
    option.role = "option"
    option.dataset.repositoryIndex = index
    option.dataset.action = "mousedown->repository-selector#repoOptionSelected"
    option.className = this.optionClass(index)
    option.setAttribute("aria-selected", String(index === this.activeIndex))
    option.textContent = repository.full_name + (repository.private ? " (private)" : "")
    this.repoListTarget.appendChild(option)
  }

  optionId(index) {
    return `repository-selector-option-${index}`
  }

  optionClass(index) {
    const activeClass = index === this.activeIndex ? "bg-indigo-50 text-indigo-900" : "text-gray-900"
    return `block w-full px-3 py-2 text-left text-sm hover:bg-indigo-50 ${activeClass}`
  }

  openRepoList() {
    if (this.repositories.length) {
      this.repoListTarget.classList.remove("hidden")
      this.repoSelectTarget.setAttribute("aria-expanded", "true")
    }
  }

  closeRepoList() {
    this.repoListTarget.classList.add("hidden")
    this.repoSelectTarget.setAttribute("aria-expanded", "false")
  }

  updateRepoDisabledState() {
    this.repoSelectTarget.disabled = this.selectedCredential() === null || this.loading
    this.repoClearTarget.disabled = this.repoSelectTarget.disabled || !this.repoSelectTarget.value
  }

  updateRepoClearState() {
    this.repoClearTarget.disabled = this.repoSelectTarget.disabled || !this.repoSelectTarget.value
  }

  updateSortDisabledState() {
    if (this.hasSortSelectTarget) this.sortSelectTarget.disabled = this.repositories.length === 0
  }

  clearOtherCredential(type) {
    if (type === "token" && this.hasInstallationSelectTarget) this.installationSelectTarget.value = ""
    if (type === "installation" && this.hasTokenSelectTarget) this.tokenSelectTarget.value = ""
  }
}
