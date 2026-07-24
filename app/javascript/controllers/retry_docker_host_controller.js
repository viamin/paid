import { Controller } from "@hotwired/stimulus"

// Keeps the manual Docker host select in the retry form in sync with the
// currently-selected runner. The server is the source of truth for
// credential-aware runner compatibility, so we refetch options on every
// runner change rather than filtering client-side.
export default class extends Controller {
  static targets = ["runnerSelect", "dockerHostSelect"]
  static values = {
    dockerHostOptionsUrl: String,
    initialRunnerIdentifier: { type: String, default: "" },
    initialSelectedHostIdentifier: { type: String, default: "" }
  }

  connect() {
    this._dockerHostRequestInFlight = false
    if (this.hasDockerHostSelectTarget && this.initialSelectedHostIdentifierValue) {
      this.dockerHostSelectTarget.dataset.previousSelection =
        this.initialSelectedHostIdentifierValue
    }
  }

  runnerChanged() {
    this.refreshDockerHostOptions()
  }

  async refreshDockerHostOptions() {
    if (!this.hasDockerHostSelectTarget || !this.hasDockerHostOptionsUrlValue) return
    if (this._dockerHostRequestInFlight) return

    const url = new URL(this.dockerHostOptionsUrlValue, window.location.origin)
    const runnerIdentifier = this.runnerIdentifierForRequest()
    if (runnerIdentifier) {
      url.searchParams.set("runner", runnerIdentifier)
    } else {
      url.searchParams.delete("runner")
    }

    this._dockerHostRequestInFlight = true
    this.dockerHostSelectTarget.dataset.loading = "true"

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        credentials: "same-origin"
      })

      if (!response.ok) {
        console.error("Failed to refresh retry docker host options", {
          status: response.status,
          statusText: response.statusText
        })
        return
      }

      const payload = await response.json()
      this.populateDockerHostSelect(payload)
    } catch (error) {
      console.error("Unexpected error refreshing retry docker host options", error)
    } finally {
      this._dockerHostRequestInFlight = false
      delete this.dockerHostSelectTarget.dataset.loading
    }
  }

  runnerIdentifierForRequest() {
    if (!this.hasRunnerSelectTarget) return null
    const value = this.runnerSelectTarget.value
    return value === "" ? null : value
  }

  populateDockerHostSelect(payload) {
    const select = this.dockerHostSelectTarget
    const options = Array.isArray(payload?.options) ? payload.options : []
    const previousSelection = Object.prototype.hasOwnProperty.call(select.dataset, "previousSelection")
      ? select.dataset.previousSelection
      : select.value
    const selectedHostIdentifier = payload?.selected_host_identifier
    const previousStillVisible = options.some(
      ([, value]) => value === previousSelection
    )
    const selectedHostStillVisible = selectedHostIdentifier &&
      options.some(([, value]) => value === selectedHostIdentifier)

    select.innerHTML = ""

    options.forEach(([label, value]) => {
      const option = document.createElement("option")
      option.value = value
      option.textContent = label
      select.appendChild(option)
    })

    let nextSelection
    if (previousStillVisible) {
      nextSelection = previousSelection
    } else if (selectedHostStillVisible) {
      nextSelection = selectedHostIdentifier
    } else {
      nextSelection = ""
    }

    select.value = nextSelection
    select.dataset.previousSelection = nextSelection
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
