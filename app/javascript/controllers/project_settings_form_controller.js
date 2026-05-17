import { Controller } from "@hotwired/stimulus"

const SUBMITTABLE_INPUT_TYPES = new Set([
  "date",
  "datetime-local",
  "email",
  "month",
  "number",
  "password",
  "search",
  "tel",
  "text",
  "time",
  "url",
  "week"
])

export default class extends Controller {
  static targets = ["saveButton"]

  submitOnEnter(event) {
    if (!this.shouldSubmitOnEnter(event)) return

    event.preventDefault()
    this.element.requestSubmit(this.saveButtonTarget)
  }

  shouldSubmitOnEnter(event) {
    return event.key === "Enter" &&
      !event.defaultPrevented &&
      !event.isComposing &&
      !event.shiftKey &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      this.hasSaveButtonTarget &&
      this.submittableInput(event.target)
  }

  submittableInput(target) {
    if (!target || target.tagName !== "INPUT") return false

    return SUBMITTABLE_INPUT_TYPES.has(target.type)
  }
}
