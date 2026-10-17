import { Controller } from "@hotwired/stimulus"

// @spec CHAT-SESSION-PREFERENCES-003
// Refreshes the new-chat dialog's runner/model choices whenever the selected
// project changes, so tiers the project's policy forbids are never offered.
// The server stays the authority: a failed or stale refresh never widens what
// ChatSessionsController accepts on create.
export default class extends Controller {
  static targets = ["projectSelect", "runnerModelSelect"]
  static values = { url: String }

  connect() {
    this.requestSequence = 0
    const blank = Array.from(this.runnerModelSelectTarget.options).find((option) => option.value === "")
    this.placeholder = blank?.textContent || "Choose a runner and model"
  }

  async projectChanged() {
    const requestId = ++this.requestSequence
    const projectId = this.projectSelectTarget.value
    const url = projectId ? `${this.urlValue}?project_id=${encodeURIComponent(projectId)}` : this.urlValue

    this.runnerModelSelectTarget.disabled = true

    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      // A slower response for an earlier project choice must not clobber the
      // choices for the currently selected one.
      if (requestId !== this.requestSequence) return

      this.replaceOptions(data.options || [])
    } catch {
      // Network failure leaves the current choices in place; create still
      // rejects combinations the selected project's policy forbids.
    } finally {
      if (requestId === this.requestSequence) this.runnerModelSelectTarget.disabled = false
    }
  }

  replaceOptions(options) {
    const select = this.runnerModelSelectTarget
    const previous = select.value

    select.options.length = 0
    select.add(new Option(this.placeholder, ""))

    options.forEach((option) => select.add(new Option(option.label, option.value)))
    select.value = options.some((option) => option.value === previous) ? previous : ""
  }
}
