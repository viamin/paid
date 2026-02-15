import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tokenSelect", "repoSelect", "owner", "repo", "githubId", "defaultBranch", "loading", "repoGroup"]

  connect() {
    this.updateRepoVisibility()
  }

  async tokenChanged() {
    const tokenId = this.tokenSelectTarget.value
    this.clearRepoSelect()

    if (!tokenId) {
      this.updateRepoVisibility()
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

      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const repos = await response.json()
      this.populateRepoSelect(repos)
    } catch (_error) {
      this.showError("Failed to load repositories. Please try again.")
    } finally {
      this.hideLoading()
      this.updateRepoVisibility()
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
    this.repoSelectTarget.innerHTML = '<option value="">Select a token first...</option>'
    this.clearHiddenFields()
  }

  clearHiddenFields() {
    this.ownerTarget.value = ""
    this.repoTarget.value = ""
    this.githubIdTarget.value = ""
    this.defaultBranchTarget.value = ""
  }

  showLoading() {
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

  updateRepoVisibility() {
    if (this.hasRepoGroupTarget) {
      const hasToken = this.tokenSelectTarget.value !== ""
      this.repoGroupTarget.classList.toggle("hidden", !hasToken)
    }
  }
}
