import { Controller } from "@hotwired/stimulus"

// @spec INBOX-FOUNDATION-009 @spec INBOX-FOUNDATION-010
export default class extends Controller {
  static targets = ["dialog", "kindOption", "projectOption", "projectSearch", "trigger"]

  open() {
    this.dialogTarget.showModal()
    this.projectSearchTarget.focus()
  }

  close() {
    this.dialogTarget.close()
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  closed() {
    this.triggerTarget.focus()
  }

  apply() {
    this.close()
  }

  filterProjects() {
    this.refreshProjectOptions(this.selectedValues("kinds[]"))
  }

  // @spec INBOX-FOUNDATION-010
  kindChanged(event) {
    if (event.target.name !== "kinds[]") return

    this.refreshProjectOptions(this.selectedValues("kinds[]"))
  }

  // @spec INBOX-FOUNDATION-010
  projectChanged(event) {
    if (event.target.name !== "project_ids[]") return

    this.refreshKindOptions(this.selectedValues("project_ids[]"))
  }

  refreshKindOptions(selectedProjectIds) {
    this.kindOptionTargets.forEach((option) => {
      this.updateOption(option, this.allowed(option, "projectIds", selectedProjectIds))
    })
  }

  refreshProjectOptions(selectedKinds) {
    const query = this.projectSearchTarget.value.trim().toLowerCase()
    this.projectOptionTargets.forEach((option) => {
      const available = this.allowed(option, "kindIds", selectedKinds)
      const matchesQuery = query.length === 0 || Boolean(option.dataset.projectName?.includes(query))
      this.updateOption(option, available, matchesQuery)
    })
  }

  selectedValues(name) {
    return Array.from(this.element.querySelectorAll(`input[name="${name}"]:checked`), (input) => input.value)
  }

  allowed(option, datasetKey, selectedValues) {
    if (selectedValues.length === 0) return true

    const availableValues = option.dataset[datasetKey]?.split(",") || []
    return selectedValues.some((value) => availableValues.includes(value))
  }

  updateOption(option, available, matchesQuery = true) {
    option.hidden = !(available && matchesQuery)
    const input = option.querySelector("input[type=\"checkbox\"]")
    if (!available) input.checked = false
  }
}
