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
    const query = this.projectSearchTarget.value.trim().toLowerCase()

    this.projectOptionTargets.forEach((option) => {
      option.hidden = query.length > 0 && !option.dataset.projectName?.includes(query)
    })
  }

  // Selecting a Type narrows the Project list to projects with items of that
  // kind, so the operator can never build a combination that would render an
  // empty list (#4276).
  kindChanged(event) {
    if (event.target.name !== "kind") return

    const selectedKind = event.target.value
    this.narrow(this.projectOptionTargets, "kindIds", selectedKind, "project_id")
  }

  // Selecting a Project narrows the Type list to kinds with items in that
  // project.
  projectChanged(event) {
    if (event.target.name !== "project_id") return

    const selectedProjectId = event.target.value
    this.narrow(this.kindOptionTargets, "projectIds", selectedProjectId, "kind")
  }

  narrow(options, datasetKey, selectedValue, resetFieldName) {
    options.forEach((option) => {
      const input = option.querySelector("input[type=\"radio\"]")
      const allowedValues = option.dataset[datasetKey]
      const isAllOption = input.value === ""
      const allowed = isAllOption || !selectedValue || allowedValues?.split(",").includes(selectedValue)

      option.hidden = !allowed
      if (!allowed && input.checked) {
        input.checked = false
        this.element.querySelector(`input[name="${resetFieldName}"][value=""]`).checked = true
      }
    })
  }
}
