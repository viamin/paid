import { Controller } from "@hotwired/stimulus"

// @spec INBOX-FOUNDATION-009 OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["dialog", "kindOption", "projectOption", "trigger"]

  open() {
    this.dialogTarget.showModal()
    this.dialogTarget.querySelector("input")?.focus()
  }

  close() { this.dialogTarget.close() }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  closed() { this.triggerTarget.focus() }

  apply() { this.close() }

  kindChanged(event) {
    if (event.target.name === "q[kind_in][]") this.refreshOptions()
  }

  projectChanged(event) {
    if (event.target.name === "q[project_id_in][]") this.refreshOptions()
  }

  refreshOptions() {
    this.refreshKindOptions(this.selectedValues("q[project_id_in][]"))
    this.refreshProjectOptions(this.selectedValues("q[kind_in][]"))
  }

  refreshKindOptions(projectIds) {
    this.kindOptionTargets.forEach((option) => this.updateOption(option, this.allowed(option, "projectIds", projectIds)))
  }

  refreshProjectOptions(kinds) {
    this.projectOptionTargets.forEach((option) => this.updateOption(option, this.allowed(option, "kindIds", kinds)))
  }

  selectedValues(name) {
    return Array.from(this.element.querySelectorAll(`input[name="${name}"]:checked`)).map((input) => input.value)
  }

  allowed(option, datasetKey, values) {
    return values.length === 0 || values.some((value) => option.dataset[datasetKey]?.split(",").includes(value))
  }

  updateOption(option, allowed) { option.hidden = !allowed }
}
