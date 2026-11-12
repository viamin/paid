import { Controller } from "@hotwired/stimulus"

// Projects the existing detail controls into the sticky header without owning
// their behavior. The original control remains the mutation/navigation source,
// so policy checks, confirmation, Turbo, validation, and loading state stay in
// the lane partial that already owns them.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["area", "source", "status"]

  connect() {
    this.renderActions()
    this.observer = new MutationObserver(() => this.renderActions())
    this.observer.observe(this.sourceTarget, {
      attributes: true,
      attributeFilter: ["aria-busy", "aria-disabled", "aria-label", "disabled", "value"],
      childList: true,
      subtree: true
    })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  activate(event) {
    const source = this.controls()[Number(event.currentTarget.dataset.sourceIndex)]
    if (!source || this.disabled(source)) return

    this.statusTarget.textContent = `${this.labelFor(source)} activated.`
    source.click()
  }

  renderActions() {
    this.areaTarget.replaceChildren(...this.controls().map((control, index) => this.mirror(control, index)))
  }

  controls() {
    return Array.from(this.sourceTarget.querySelectorAll("a[href], button, input[type='submit']"))
  }

  mirror(control, index) {
    const mirror = document.createElement("button")
    mirror.type = "button"
    mirror.textContent = this.labelFor(control)
    mirror.disabled = this.disabled(control)
    mirror.dataset.action = "inbox-detail-actions#activate"
    mirror.dataset.sourceIndex = index
    mirror.className = "inline-flex min-h-9 items-center rounded-md border border-gray-300 bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-sm hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50"
    return mirror
  }

  labelFor(control) {
    return control.getAttribute("aria-label") || control.value || control.textContent.trim()
  }

  disabled(control) {
    return control.disabled || control.getAttribute("aria-disabled") === "true"
  }
}
