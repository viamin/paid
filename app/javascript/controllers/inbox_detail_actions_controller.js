import { Controller } from "@hotwired/stimulus"

// Projects the existing detail controls into one persistent action area. The
// proxies deliberately click their original controls, preserving the current
// form endpoint, confirmation, Turbo frame, policy, validation, and response.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["toolbar", "controls", "source"]

  connect() {
    this.proxies = []
    this.projectActions()
    this.sourceTarget.addEventListener("turbo:submit-start", this.disableSubmittingAction)
    this.sourceTarget.addEventListener("turbo:submit-end", this.enableSubmittingAction)
  }

  disconnect() {
    this.sourceTarget?.removeEventListener("turbo:submit-start", this.disableSubmittingAction)
    this.sourceTarget?.removeEventListener("turbo:submit-end", this.enableSubmittingAction)
  }

  projectActions() {
    this.actionControls().forEach((control) => this.addProxy(control))
    this.toolbarTarget.classList.toggle("hidden", this.proxies.length === 0)
  }

  actionControls() {
    return Array.from(this.sourceTarget.querySelectorAll("a[href], button, input[type='submit'], input[type='image']"))
      .filter((control) => this.labelFor(control).length > 0)
  }

  addProxy(control) {
    const proxy = document.createElement("button")
    proxy.type = "button"
    proxy.textContent = this.labelFor(control)
    proxy.disabled = control.disabled
    proxy.className = "shrink-0 rounded-md bg-white px-3 py-2 text-sm font-medium text-gray-700 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50"
    proxy.setAttribute("data-inbox-detail-action-proxy", "")
    proxy.addEventListener("click", () => this.activate(control))
    this.controlsTarget.append(proxy)
    this.proxies.push({ control, proxy })
  }

  activate(control) {
    if (control.disabled) return

    control.click()
  }

  disableSubmittingAction = (event) => {
    this.proxiesFor(event.target).forEach(({ proxy }) => {
      proxy.disabled = true
      proxy.setAttribute("aria-busy", "true")
    })
  }

  enableSubmittingAction = (event) => {
    this.proxiesFor(event.target).forEach(({ control, proxy }) => {
      proxy.disabled = control.disabled
      proxy.removeAttribute("aria-busy")
    })
  }

  proxiesFor(form) {
    return this.proxies.filter(({ control }) => control.closest("form") === form)
  }

  labelFor(control) {
    return (control.getAttribute("aria-label") || control.value || control.textContent || "").trim()
  }
}
