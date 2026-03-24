import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tokenSelect", "repoSelect", "owner", "repo", "githubId", "defaultBranch", "loading"]

  connect() {
    this.updateRepoDisabledState()
  }

  async tokenChanged() {
    const tokenId = this.tokenSelectTarget.value
    this.clearRepoSelect()

    if (!tokenId) {
      this.updateRepoDisabledState()
      return
    }

    this.showLoading()

    try {
      const response = await fetch(`/github_tokens/${tokenId}/repositories`, {
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
        }
      })

      if (!response.ok) {
        console.error("Failed to load repositories:", { status: response.status, statusText: response.statusText })

        if (response.status === 401 || response.status === 403) {
          this.showError("Unable to load repositories: token is invalid or lacks permissions.")
        } else {
          this.showError(`Failed to load repositories (HTTP ${response.status}). Please try again.`)
        }
        return
      }

      const repos = await response.json()
      this.populateRepoSelect(repos)
    } catch (error) {
      console.error("Unexpected error loading repositories:", error)
      this.showError("Failed to load repositories. Please check your connection and try again.")
    } finally {
      this.hideLoading()
      this.updateRepoDisabledState()
    }
  }

  repoSelected() {
    const selectedOption = this.repoSelectTarget.selectedOptions[0]

    if (!selectedOption || !selectedOption.value) {
      this.clearHiddenFields()
      return
    }

    this.ownerTarget.value = selectedOption.dataset.owner
    this.repoTarget.value = selectedOption.dataset.repo
    this.githubIdTarget.value = selectedOption.dataset.githubId
    this.defaultBranchTarget.value = selectedOption.dataset.defaultBranch
  }

  // Private

  populateRepoSelect(repos) {
    this.clearRepoSelect()

    const prompt = document.createElement("option")
    prompt.value = ""
    prompt.textContent = `Select a repository... (${repos.length} available)`
    this.repoSelectTarget.appendChild(prompt)

    repos
      .sort((a, b) => a.full_name.localeCompare(b.full_name))
      .forEach((repo) => {
        const option = document.createElement("option")
        option.value = repo.full_name
        option.textContent = repo.full_name + (repo.private ? " (private)" : "")
        option.dataset.owner = repo.owner
        option.dataset.repo = repo.name
        option.dataset.githubId = repo.id
        option.dataset.defaultBranch = repo.default_branch
        this.repoSelectTarget.appendChild(option)
      })
  }

  clearRepoSelect() {
    const hasToken = this.tokenSelectTarget.value !== ""
    const placeholder = hasToken ? "Select a repository..." : "Select a token first..."
    this.repoSelectTarget.innerHTML = `<option value="">${placeholder}</option>`
    this.clearHiddenFields()
  }

  clearHiddenFields() {
    this.ownerTarget.value = ""
    this.repoTarget.value = ""
    this.githubIdTarget.value = ""
    this.defaultBranchTarget.value = ""
  }

  showLoading() {
    this.repoSelectTarget.innerHTML = '<option value="">Loading repositories...</option>'
    if (this.hasLoadingTarget) this.loadingTarget.classList.remove("hidden")
  }

  hideLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.classList.add("hidden")
  }

  showError(message) {
    this.repoSelectTarget.innerHTML = ""
    const errorOption = document.createElement("option")
    errorOption.value = ""
    errorOption.textContent = message
    this.repoSelectTarget.appendChild(errorOption)
  }

  updateRepoDisabledState() {
    const hasToken = this.tokenSelectTarget.value !== ""
    if (this.hasRepoSelectTarget) {
      this.repoSelectTarget.disabled = !hasToken
    }
  }
}
