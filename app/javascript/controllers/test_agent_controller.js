import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "result"]
  static values = { url: String }

  disconnect() {
    this.clearDismissTimer()
  }

  async test() {
    this.showLoading()

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": this.csrfToken,
          "Accept": "application/json"
        },
        redirect: "follow"
      })

      if (!this.element.isConnected) return

      const contentType = response.headers.get("content-type") || ""

      if (response.redirected) {
        this.showError("unexpected", "Session expired. Please refresh the page and sign in again.")
        return
      }

      if (!contentType.includes("application/json")) {
        if (response.status === 404) {
          this.showError("unexpected", "Provider not found. It may have been deleted. Please refresh the page.")
        } else {
          this.showError("unexpected", "Unexpected server response. Please try again.")
        }
        return
      }

      if (response.status === 401) {
        this.showError("authentication", "Session expired. Please refresh the page and sign in again.")
        return
      }

      if (response.status === 403) {
        this.showError("unexpected", "You do not have permission to test this provider.")
        return
      }

      if (response.status === 404) {
        this.showError("unexpected", "Provider not found. It may have been deleted. Please refresh the page.")
        return
      }

      if (response.status === 429) {
        const retryData = await response.json()
        if (!this.element.isConnected) return
        this.showError("rate_limited", retryData.message || "Please wait before testing again.")
        return
      }

      if (!response.ok) {
        this.showError("unexpected", `Server responded with ${response.status}`)
        return
      }

      const data = await response.json()

      if (!this.element.isConnected) return

      if (data.success) {
        this.showSuccess(data.message)
      } else {
        this.showError(data.error_type, data.message)
      }
    } catch (error) {
      if (!this.element.isConnected) return
      this.showError("unexpected", error.message)
    }
  }

  showLoading() {
    this.clearDismissTimer()
    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Testing..."
    this.resultTarget.innerHTML = `
      <span role="status" aria-live="polite" aria-busy="true" class="inline-flex items-center gap-1 text-xs text-gray-500">
        <svg class="h-3 w-3 animate-spin" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
        </svg>
        Testing agent...
      </span>
    `
  }

  showSuccess(message) {
    this.resetButton()
    this.resultTarget.innerHTML = `
      <span role="status" class="inline-flex items-center gap-1 rounded-md bg-green-100 px-2 py-1 text-xs font-medium text-green-700">
        <svg class="h-3 w-3" aria-hidden="true" focusable="false" fill="currentColor" viewBox="0 0 20 20">
          <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/>
        </svg>
        ${this.escapeHtml(message)}
      </span>
    `
    this.autoDismiss()
  }

  showError(errorType, message) {
    this.resetButton()
    const troubleshooting = this.troubleshootingFor(errorType)
    this.resultTarget.innerHTML = `
      <div role="alert" class="mt-1 rounded-md bg-red-50 px-2 py-1">
        <span class="inline-flex items-center gap-1 text-xs font-medium text-red-700">
          <svg class="h-3 w-3" aria-hidden="true" focusable="false" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
          </svg>
          Test failed
        </span>
        <p class="mt-0.5 text-xs text-red-600">${this.escapeHtml(message)}</p>
        <p class="mt-0.5 text-xs text-gray-500">${this.escapeHtml(troubleshooting)}</p>
      </div>
    `
  }

  troubleshootingFor(errorType) {
    const messages = {
      connection: "Could not reach the agent. Verify the provider URL is correct and the agent container is running.",
      authentication: "Authentication failed. Check that the API key or token for this provider is valid and has not expired.",
      timeout: "The agent did not respond in time. Ensure the agent container has sufficient resources and is not in a crash loop.",
      installation: "The provider CLI is not installed in the agent container. Verify the container image includes this provider and that it is on the PATH.",
      rate_limited: "A test was recently run for this provider. Please wait 30 seconds between tests.",
      unexpected: "An unexpected error occurred. Check the agent logs for more details."
    }
    return messages[errorType] || messages.unexpected
  }

  resetButton() {
    this.buttonTarget.disabled = false
    this.buttonTarget.textContent = "Test Agent"
  }

  autoDismiss() {
    this.clearDismissTimer()
    this.dismissTimer = window.setTimeout(() => {
      if (this.hasResultTarget) {
        this.resultTarget.innerHTML = ""
      }
    }, 10000)
  }

  clearDismissTimer() {
    if (this.dismissTimer) {
      window.clearTimeout(this.dismissTimer)
      this.dismissTimer = null
    }
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name=csrf-token]")
    return meta ? meta.content : ""
  }
}
