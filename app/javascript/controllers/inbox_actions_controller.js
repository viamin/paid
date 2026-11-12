import { Controller } from "@hotwired/stimulus"

// Projects existing Inbox detail controls into a single sticky action area.
// The proxies invoke the original controls, keeping their policies, Turbo
// behavior, confirmations, and submit/loading states as the sole action path.
// @spec OPERATOR-INBOX-027
export default class extends Controller {
  static targets = ["bar"]

  connect() {
    this.renderActions()
  }

  renderActions() {
    const controls = this.controls()
    if (controls.length === 0 || !this.hasBarTarget) return

    this.barTarget.replaceChildren(...controls.map((control) => this.proxyFor(control)))
    this.barTarget.hidden = false
  }

  controls() {
    return Array.from(this.element.querySelectorAll("a[href], form"))
      .filter((control) => !this.barTarget.contains(control))
      .filter((control) => this.labelFor(control).length > 0)
  }

  proxyFor(control) {
    const proxy = document.createElement("button")
    proxy.type = "button"
    proxy.textContent = this.labelFor(control)
    proxy.className = "rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500"
    proxy.addEventListener("click", () => this.activate(control))
    return proxy
  }

  activate(control) {
    if (control.tagName === "A") {
      control.click()
      return
    }

    this.submitterFor(control)?.click()
  }

  submitterFor(form) {
    return form.querySelector("button[type='submit'], input[type='submit'], button:not([type])")
  }

  labelFor(control) {
    if (control.tagName === "A") return control.textContent.trim()

    return this.submitterFor(control)?.textContent?.trim() || this.submitterFor(control)?.value?.trim() || ""
  }
}
