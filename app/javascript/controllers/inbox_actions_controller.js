import { Controller } from "@hotwired/stimulus"

// Projects Inbox detail controls that opt in via `data-inbox-action` into a
// single sticky action area. The proxies invoke the original controls, keeping
// their policies, Turbo behavior, confirmations, and submit/loading states as
// the sole action path. Only explicitly marked item actions are promoted;
// contextual reference links (issue trees, evidence records) stay in the body
// so the bar height does not grow with issue/evidence count.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["bar"]

  connect() {
    this.disabledObservers = []
    this.renderActions()
  }

  disconnect() {
    this.disabledObservers.forEach((observer) => observer.disconnect())
  }

  renderActions() {
    if (!this.hasBarTarget) return

    const controls = this.controls()
    if (controls.length === 0) return

    this.barTarget.replaceChildren(...controls.map((control) => this.proxyFor(control)))
    this.barTarget.hidden = false
  }

  controls() {
    const selector = "[data-inbox-action]"
    return Array.from(this.element.querySelectorAll(selector))
      .filter((control) => !this.barTarget.contains(control))
      .filter((control) => this.labelFor(control).length > 0)
  }

  proxyFor(control) {
    const proxy = document.createElement("button")
    proxy.type = "button"
    proxy.textContent = this.labelFor(control)
    proxy.className = "rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500"
    proxy.addEventListener("click", () => this.activate(control))
    this.observeDisabled(control, proxy)
    return proxy
  }

  activate(control) {
    control.click()
  }

  observeDisabled(control, proxy) {
    if (control.tagName === "A") return

    const synchronize = () => { proxy.disabled = control.disabled }
    const observer = new window.MutationObserver(synchronize)
    observer.observe(control, { attributes: true, attributeFilter: ["disabled"] })
    this.disabledObservers.push(observer)
    synchronize()
  }

  labelFor(control) {
    return control.textContent?.trim() || control.value?.trim() || ""
  }
}
