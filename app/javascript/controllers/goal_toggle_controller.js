import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["issueSection", "prSection", "prHeading", "prDescription"]

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

    if (goal === "review") {
      this.prHeadingTargets.forEach((el) => {
        el.textContent = "Select PR to Review"
      })
      this.prDescriptionTargets.forEach((el) => {
        el.textContent =
          "Choose a pull request for the agent to review and post comments on."
      })
    } else {
      this.prHeadingTargets.forEach((el) => {
        el.textContent = "Or Work on an Existing PR"
      })
      this.prDescriptionTargets.forEach((el) => {
        el.textContent =
          "Push changes to an existing pull request's branch instead of creating a new one."
      })
    }
  }
}
