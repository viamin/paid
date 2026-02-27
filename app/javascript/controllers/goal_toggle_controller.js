import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["issueSection", "prSection"]

  connect() {
    this.toggle()
  }

  toggle() {
    const selected = this.element.querySelector("input[name='goal']:checked")
    const showSections = selected && selected.value !== "create_issue"

    ;[...this.issueSectionTargets, ...this.prSectionTargets].forEach((el) => {
      el.hidden = !showSections

      el.querySelectorAll("input, select, textarea, button").forEach(
        (control) => {
          control.disabled = !showSections
        }
      )
    })
  }
}
