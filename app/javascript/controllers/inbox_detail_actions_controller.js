import { Controller } from "@hotwired/stimulus"

// Mirrors every detail action into the persistent action toolbar without
// duplicating its form, route, confirmation, or Turbo behavior. The original
// action remains beside the explanation and any required decision inputs.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["actions"]

  connect() {
    this.addShortcuts()
  }

  addShortcuts() {
    this.actionElements().forEach((element, index) => {
      const label = this.labelFor(element)
      if (!label) return

      const shortcut = this.shortcutFor(element, label, index)
      this.actionsTarget.append(shortcut)
    })
  }

  actionElements() {
    return Array.from(this.element.querySelectorAll("a, form"))
      .filter((element) => !this.actionsTarget.contains(element))
  }

  labelFor(element) {
    if (element.tagName === "A") return element.textContent.trim()

    const submitter = this.submitterFor(element)
    return submitter?.value || submitter?.textContent.trim()
  }

  shortcutFor(element, label, index) {
    const shortcut = document.createElement("button")
    shortcut.type = "button"
    shortcut.textContent = label
    shortcut.setAttribute("aria-label", label)
    shortcut.dataset.testid = "inbox-detail-action-shortcut"
    shortcut.className = "inline-flex items-center rounded-md border border-gray-300 bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-sm hover:bg-gray-50"
    shortcut.addEventListener("click", () => this.activate(element, shortcut))
    element.id ||= `inbox-detail-action-${index}`
    shortcut.setAttribute("aria-controls", element.id)
    return shortcut
  }

  activate(element, shortcut) {
    const submitter = element.tagName === "FORM" ? this.submitterFor(element) : element
    if (!submitter) return

    element.addEventListener("turbo:submit-start", () => { shortcut.disabled = true }, { once: true })
    element.addEventListener("turbo:submit-end", () => { shortcut.disabled = false }, { once: true })
    submitter.click()
  }

  submitterFor(form) {
    return form.querySelector("button[type='submit'], input[type='submit'], button:not([type])")
  }
}
