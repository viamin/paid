import { Controller } from "@hotwired/stimulus"

// @spec INBOX-FOUNDATION-009 @spec INBOX-FOUNDATION-010
export default class extends Controller {
  static targets = ["dialog", "kindOption", "projectOption", "trigger"]

  open() {
    this.dialogTarget.showModal()
    this.dialogTarget.querySelector("input")?.focus()
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

  // Selecting one or more types narrows the Project list to projects with at
  // least one selected type. The server remains the source of truth.
  kindChanged(event) {
    if (event.target.name !== "q[kind_in][]") return

    this.refreshOptions()
  }

  // Selecting a Project narrows the Type list to kinds with items in that
  // project.
  projectChanged(event) {
    if (event.target.name !== "q[project_id_in][]") return

    this.refreshOptions()
  }

  refreshOptions() {
    this.refreshKindOptions(this.selectedValues("q[project_id_in][]"))
    this.refreshProjectOptions(this.selectedValues("q[kind_in][]"))
  }

  refreshKindOptions(selectedProjectIds) {
    this.kindOptionTargets.forEach((option) => {
      this.updateOption(option, this.allowed(option, "projectIds", selectedProjectIds))
    })
  }

  refreshProjectOptions(selectedKinds) {
    this.projectOptionTargets.forEach((option) => {
      this.updateOption(option, this.allowed(option, "kindIds", selectedKinds))
    })
  }

  selectedValues(name) {
    return Array.from(this.element.querySelectorAll(`input[name="${name}"]:checked`)).map((input) => input.value)
  }

  allowed(option, datasetKey, selectedValues) {
    if (selectedValues.length === 0) return true

    return selectedValues.some((value) => option.dataset[datasetKey]?.split(",").includes(value))
  }

  updateOption(option, allowed) {
    option.hidden = !allowed
  }
}
