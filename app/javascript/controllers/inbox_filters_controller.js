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
    this.refreshOptions()
  }

  // Selecting a Type narrows the Project list to projects with items of that
  // kind, so the operator can never build a combination that would render an
  // empty list (#4276).
  kindChanged(event) {
    if (event.target.name !== "kind") return

    this.refreshOptions()
  }

  // Selecting a Project narrows the Type list to kinds with items in that
  // project.
  projectChanged(event) {
    if (event.target.name !== "project_id") return

    this.refreshOptions()
  }

  // Single writer for option visibility so the project search and the
  // kind/project narrowing compose instead of clobbering each other: a
  // project option stays visible only while it both matches the search
  // query and carries items of the selected kind. Hiding through the
  // search never drops a selection; a selection excluded by the other
  // group's filter resets to that group's "All" option.
  refreshOptions() {
    const selectedKind = this.selectedValue("kind")
    const selectedProjectId = this.selectedValue("project_id")
    const query = this.projectSearchTarget.value.trim().toLowerCase()

    this.kindOptionTargets.forEach((option) => {
      this.updateOption(option, this.allowed(option, "projectIds", selectedProjectId))
    })
    this.projectOptionTargets.forEach((option) => {
      const allowed = this.allowed(option, "kindIds", selectedKind)
      const matchesQuery = query.length === 0 || Boolean(option.dataset.projectName?.includes(query))
      this.updateOption(option, allowed, matchesQuery)
    })
  }

  selectedValue(name) {
    return this.element.querySelector(`input[name="${name}"]:checked`)?.value || ""
  }

  // The "All" option (empty radio value) is always allowed; a concrete
  // option must list the other group's current selection in its matrix data.
  allowed(option, datasetKey, selectedValue) {
    const input = option.querySelector("input[type=\"radio\"]")
    if (input.value === "" || !selectedValue) return true

    return Boolean(option.dataset[datasetKey]?.split(",").includes(selectedValue))
  }

  updateOption(option, allowed, matchesQuery = true) {
    option.hidden = !(allowed && matchesQuery)

    const input = option.querySelector("input[type=\"radio\"]")
    if (!allowed && input.checked) {
      input.checked = false
      this.element.querySelector(`input[name="${input.name}"][value=""]`).checked = true
    }
  }
}
