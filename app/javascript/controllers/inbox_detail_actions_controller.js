import { Controller } from "@hotwired/stimulus"

// Places the controls already rendered by a selected Inbox lane in one sticky
// action area. Moving the original nodes deliberately preserves their policy
// gates, endpoints, Turbo attributes, confirmations, and loading behavior.
// @spec OPERATOR-INBOX-028
export default class extends Controller {
  static targets = ["area", "source"]

  connect() {
    this.movedControls = []
    this.sourceTargets.forEach((source) => {
      source.querySelectorAll("a[href], button, input[type='submit'], input[type='button']").forEach((control) => {
        this.move(control)
      })
    })
    this.areaTarget.hidden = this.movedControls.length === 0
  }

  disconnect() {
    this.movedControls?.reverse().forEach(({ control, formAttribute, placeholder }) => {
      placeholder.replaceWith(control)
      if (formAttribute === null) control.removeAttribute("form")
      else control.setAttribute("form", formAttribute)
    })
  }

  move(control) {
    const form = control.closest("form")
    const formAttribute = control.getAttribute("form")
    if (form) {
      form.id ||= `inbox-detail-action-form-${this.movedControls.length + 1}`
      control.setAttribute("form", form.id)
    }

    const placeholder = document.createComment("inbox detail action")
    control.before(placeholder)
    this.areaTarget.append(control)
    this.movedControls.push({ control, formAttribute, placeholder })
  }
}
