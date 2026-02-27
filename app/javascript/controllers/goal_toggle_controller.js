import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["issueSection", "prSection"]

  connect() {
    this.toggle()
  }

  toggle() {
    const selected = this.element.querySelector("input[name='goal']:checked")
    const showSections = selected && selected.value !== "create_issue"

    this.issueSectionTargets.forEach((el) => {
      el.hidden = !showSections
    })
    this.prSectionTargets.forEach((el) => {
      el.hidden = !showSections
    })
  }
}
