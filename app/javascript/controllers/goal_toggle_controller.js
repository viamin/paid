import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "issueSection",
    "issueHeading",
    "issueDropdown",
    "issueTable",
    "prSection",
    "prHeading",
    "prDescription",
    "prDropdown",
    "prTable",
    "prioritySection",
    "runnerSelect",
    "dockerHostSelect",
    "blockedBySection",
  ]
  static values = {
    currentGoal: String,
    runnerDefaults: Object,
    runnerManuallySelected: { type: Boolean, default: false },
    dockerHostOptionsUrl: String,
  }

  connect() {
    this.toggle()
  }

  runnerChanged() {
    this.runnerManuallySelectedValue = true
    this.refreshDockerHostOptions()
  }

  toggle() {
    const previousGoal = this.currentGoalValue || "create_pr"
    const selected = this.element.querySelector("input[name='goal']:checked")
    const goal = selected ? selected.value : "create_pr"

    const showIssue = goal === "create_pr" || goal === "enhance_issue"
    const showPr = goal === "create_pr" || goal === "review"
    const isReview = goal === "review"
    const isEnhanceIssue = goal === "enhance_issue"
    const isCreateIssue = goal === "create_issue"
    const showPriority = !isReview

    this.issueSectionTargets.forEach((el) => {
      el.hidden = !showIssue
      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          if (!control.hasAttribute("data-permanently-disabled")) {
            control.disabled = !showIssue
          }
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

    this.blockedBySectionTargets.forEach((el) => {
      el.hidden = !isCreateIssue
      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          if (!control.hasAttribute("data-permanently-disabled")) {
            control.disabled = !isCreateIssue
          }
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

    // Toggle between dropdown (create_pr) and table (enhance_issue) for issues.
    this.issueDropdownTargets.forEach((el) => {
      el.hidden = isEnhanceIssue
      el.querySelectorAll("select").forEach((control) => {
        control.disabled = isEnhanceIssue || !showIssue
      })
    })

    this.issueTableTargets.forEach((el) => {
      el.hidden = !isEnhanceIssue
      el.querySelectorAll("input[type='checkbox']").forEach((control) => {
        if (!control.hasAttribute("data-permanently-disabled")) {
          control.disabled = !isEnhanceIssue
        }
      })
    })

    this.issueHeadingTargets.forEach((el) => {
      el.textContent = isEnhanceIssue
        ? "Select Issues to Enhance"
        : "Select Issue"
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

    this.syncRunnerDefault(previousGoal, goal)
    this.currentGoalValue = goal
    this.refreshDockerHostOptions()
  }

  syncRunnerDefault(previousGoal, goal) {
    if (!this.hasRunnerSelectTarget) return

    // When "Inherit" (empty value) is selected, keep it as-is across goal changes
    if (this.runnerSelectTarget.value === "") return

    const previousDefault = this.defaultRunnerForGoal(previousGoal)
    const nextDefault = this.defaultRunnerForGoal(goal)
    if (!nextDefault) return

    const shouldSync =
      !this.runnerManuallySelectedValue ||
      this.runnerSelectTarget.value === previousDefault

    if (!shouldSync) return

    this.runnerSelectTarget.value = nextDefault
    this.runnerManuallySelectedValue = false
  }

  defaultRunnerForGoal(goal) {
    if (!this.hasRunnerDefaultsValue) return null

    return this.runnerDefaultsValue[goal] || null
  }

  // Re-fetch the docker host options whenever the resolved runner changes
  // (either via goal default or manual override). The server is the source of
  // truth for credential-aware runner compatibility, so we don't try to
  // filter the existing options client-side.
  async refreshDockerHostOptions() {
    if (!this.hasDockerHostSelectTarget || !this.hasDockerHostOptionsUrlValue) return
    if (this._dockerHostRequestInFlight) return

    const url = new URL(this.dockerHostOptionsUrlValue, window.location.origin)
    const runnerIdentifier = this.runnerIdentifierForRequest()
    if (runnerIdentifier) {
      url.searchParams.set("runner", runnerIdentifier)
    } else {
      url.searchParams.delete("runner")
    }

    this._dockerHostRequestInFlight = true
    this.dockerHostSelectTarget.dataset.loading = "true"

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        credentials: "same-origin"
      })

      if (!response.ok) {
        console.error("Failed to refresh docker host options", {
          status: response.status,
          statusText: response.statusText
        })
        return
      }

      const payload = await response.json()
      this.populateDockerHostSelect(payload)
    } catch (error) {
      console.error("Unexpected error refreshing docker host options", error)
    } finally {
      this._dockerHostRequestInFlight = false
      delete this.dockerHostSelectTarget.dataset.loading
    }
  }

  runnerIdentifierForRequest() {
    if (!this.hasRunnerSelectTarget) return null
    const value = this.runnerSelectTarget.value
    return value === "" ? null : value
  }

  populateDockerHostSelect(payload) {
    const select = this.dockerHostSelectTarget
    const options = Array.isArray(payload?.options) ? payload.options : []
    const previousSelection = select.value
    const selectedHostIdentifier = payload?.selected_host_identifier
    const previousStillVisible = options.some(
      ([, value]) => value === previousSelection
    )
    const selectedHostStillVisible = selectedHostIdentifier &&
      options.some(([, value]) => value === selectedHostIdentifier)

    select.innerHTML = ""

    options.forEach(([label, value]) => {
      const option = document.createElement("option")
      option.value = value
      option.textContent = label
      select.appendChild(option)
    })

    if (previousStillVisible) {
      select.value = previousSelection
    } else if (selectedHostStillVisible) {
      select.value = selectedHostIdentifier
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
