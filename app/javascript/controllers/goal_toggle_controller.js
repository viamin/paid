import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["issueSection", "prSection"]

  connect() {
    this.toggle()
  }

  toggle() {
    const selected = this.element.querySelector("input[name='goal']:checked")
    const goal = selected ? selected.value : "create_pr"

    const showIssue = goal === "create_pr"
    const showPr = goal === "create_pr" || goal === "review"

    this.issueSectionTargets.forEach((el) => {
      el.hidden = !showIssue
      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          control.disabled = !showIssue
        }
      )
    })

    this.prSectionTargets.forEach((el) => {
      el.hidden = !showPr
      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          control.disabled = !showPr
        }
      )
    })
  }
}
