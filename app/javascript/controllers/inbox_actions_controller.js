import { Controller } from "@hotwired/stimulus"

// Projects every existing Inbox action into the sticky detail header without
// creating a second server-side action contract for every Inbox kind. Form
// submitters retain their original form owner, so authorization, confirmation,
// Turbo navigation, and server validation remain on the existing endpoint.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["actionArea", "content"]

  connect() {
    this.projectActions()
    this.observer = new window.MutationObserver(() => this.projectActions())
    this.observer.observe(this.contentTarget, { childList: true, subtree: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  projectActions() {
    this.actionAreaTarget.replaceChildren()

    this.actionSources().forEach((source, index) => {
      this.actionAreaTarget.append(this.projectAction(source, index))
    })

    this.actionAreaTarget.hidden = this.actionAreaTarget.childElementCount === 0
  }

  actionSources() {
    return Array.from(this.contentTarget.querySelectorAll("a[href], button[type='submit'], button:not([type]), input[type='submit']"))
  }

  projectAction(source, index) {
    const projection = source.cloneNode(true)
    projection.removeAttribute("id")
    projection.dataset.inboxActionsProjection = ""

    if (source.form) projection.setAttribute("form", this.formId(source.form, index))

    return projection
  }

  formId(form, index) {
    if (!form.id) form.id = `inbox-action-form-${index}`

    return form.id
  }
}
