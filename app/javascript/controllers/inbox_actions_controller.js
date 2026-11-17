import { Controller } from "@hotwired/stimulus"

// Projects every form action in the Inbox detail, plus links that opt in via
// `data-inbox-action`, into a single sticky action area. Form-action proxies
// invoke the original controls, while navigational actions remain links with
// their native attributes. Contextual reference links (issue trees, evidence
// records) stay in the body so the bar height does not grow with issue/evidence
// count.
// The one source control designated `data-inbox-primary-action` — the control
// that performs the decision brief's primary action for its lane — is projected
// with filled primary styling, so the bar always presents a single visually
// clear primary action alongside the neutral secondary controls.
// @spec OPERATOR-INBOX-027
const PRIMARY_ATTRIBUTE = "data-inbox-primary-action"
const SECONDARY_CLASSES = "min-w-0 max-w-full whitespace-normal rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500 [overflow-wrap:anywhere]"
const PRIMARY_CLASSES = "min-w-0 max-w-full whitespace-normal rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500 [overflow-wrap:anywhere]"

export default class extends Controller {
  static targets = ["bar", "source"]

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

    const primaryIndex = controls.findIndex((control) => this.isPrimary(control))
    this.barTarget.replaceChildren(...controls.map((control, index) => this.proxyFor(control, index === primaryIndex)))
    this.barTarget.hidden = false
  }

  controls() {
    const selector = "button, input[type='submit'], input[type='image'], [data-inbox-action]"
    return Array.from(this.sourceTarget.querySelectorAll(selector))
      .filter((control) => this.labelFor(control).length > 0)
  }

  isPrimary(control) {
    return control.hasAttribute(PRIMARY_ATTRIBUTE)
  }

  proxyFor(control, primary) {
    if (control.tagName === "A") return this.linkProxyFor(control, primary)

    const proxy = document.createElement("button")
    proxy.type = "button"
    proxy.textContent = this.labelFor(control)
    proxy.className = primary ? PRIMARY_CLASSES : SECONDARY_CLASSES
    this.markPrimary(proxy, primary)
    proxy.addEventListener("click", () => this.activate(control))
    this.observeDisabled(control, proxy)
    return proxy
  }

  linkProxyFor(control, primary) {
    const proxy = control.cloneNode(false)
    proxy.textContent = this.labelFor(control)
    proxy.className = primary ? PRIMARY_CLASSES : SECONDARY_CLASSES
    this.markPrimary(proxy, primary)
    return proxy
  }

  markPrimary(proxy, primary) {
    if (primary) {
      proxy.setAttribute(PRIMARY_ATTRIBUTE, "")
    } else {
      proxy.removeAttribute(PRIMARY_ATTRIBUTE)
    }
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
