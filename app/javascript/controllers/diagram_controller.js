import { Controller } from "@hotwired/stimulus"

// Presentation and selection state stay in the browser. Neither is submitted
// as a preference or confidence signal.
// @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-011
export default class extends Controller {
  static targets = ["comment", "element", "elementId"]

  toggle(event) {
    if (this.hasCommentTarget && this.commentTarget.value.trim() !== "") {
      event.preventDefault()
      this.commentTarget.focus()
    }
  }

  select(event) {
    const element = event.currentTarget
    this.elementTargets.forEach((candidate) => {
      const selected = candidate === element
      candidate.setAttribute("aria-pressed", selected.toString())
      candidate.classList.toggle("ring-2", selected)
      candidate.classList.toggle("ring-indigo-500", selected)
    })
    this.elementIdTarget.value = element.dataset.diagramElementId
  }

  selectWithKeyboard(event) {
    if (!["Enter", " "].includes(event.key)) return

    event.preventDefault()
    this.select(event)
  }
}
