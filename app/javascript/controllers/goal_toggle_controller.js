import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "issueSection",
    "prSection",
    "prHeading",
    "prDescription",
    "prDropdown",
    "prTable",
    "prioritySection",
  ]

  connect() {
    this.toggle()
  }

  toggle() {
    const selected = this.element.querySelector("input[name='goal']:checked")
    const goal = selected ? selected.value : "create_pr"

    const showIssue = goal === "create_pr"
    const showPr = goal === "create_pr" || goal === "review"
    const isReview = goal === "review"
    const showPriority = !isReview

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
          if (!control.hasAttribute("data-permanently-disabled")) {
            control.disabled = !showPr
          }
        }
      )
    })

    this.prioritySectionTargets.forEach((el) => {
      el.hidden = !showPriority
      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          control.disabled = !showPriority
        }
      )
    })

    // Toggle between dropdown (create_pr) and table (review).
    // These blocks run after prSectionTargets above and override its enable/disable
    // for controls within the dropdown and table sub-sections.
    this.prDropdownTargets.forEach((el) => {
      el.hidden = isReview
      el.querySelectorAll("select").forEach((control) => {
        control.disabled = isReview || !showPr
      })
    })

    this.prTableTargets.forEach((el) => {
      el.hidden = !isReview
      el.querySelectorAll("input[type='checkbox']").forEach((control) => {
        // Re-enable non-disabled-by-default checkboxes when review is shown
        if (!control.hasAttribute("data-permanently-disabled")) {
          control.disabled = !isReview
        }
      })
    })

    if (isReview) {
      this.prHeadingTargets.forEach((el) => {
        el.textContent = "Select PRs to Review"
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
