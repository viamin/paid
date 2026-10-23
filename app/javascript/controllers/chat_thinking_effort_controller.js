import { Controller } from "@hotwired/stimulus"

// @spec CHAT-THINKING-EFFORT-002 CHAT-THINKING-EFFORT-003 CHAT-THINKING-EFFORT-005
// Keeps the "Thinking effort" control in sync with the "Runner and model"
// choice without a page reload. The server embeds every curated runner/model
// option's reasoning capability (allowed effort values, empty when the model
// does not support configurable reasoning at all), so this controller can
// show/hide the field and rebuild its options purely client-side whenever the
// selection changes. The server remains the authority: ChatSessionsController
// independently revalidates and normalizes the saved preference, so a stale
// or failed client-side sync here cannot persist an unsupported value.
export default class extends Controller {
  static targets = ["runnerModelSelect", "field", "select", "status"]
  static values = { models: Object, defaultLabel: String }

  connect() {
    this.sync()
  }

  // The runner/model choice changed: realign the effort options with the newly
  // selected model and tell the user when the previous effort no longer
  // applies to it.
  // @spec CHAT-THINKING-EFFORT-003
  runnerModelChanged() {
    const previous = this.selectTarget.value
    this.sync()
    this.announceIfCleared(previous, this.selectTarget.value)
  }

  sync() {
    const selection = this.runnerModelSelectTarget.value
    const allowedValues = this.modelsValue[selection] || []

    // No curated runner/model pair is selected, so there is no model to
    // resolve effort values against. The server-rendered options for the
    // session's effective model stay in place until the user picks a pair.
    if (selection === "") return

    const previous = this.selectTarget.value
    this.fieldTarget.hidden = allowedValues.length === 0
    this.rebuildOptions(allowedValues)
    this.selectTarget.value = allowedValues.includes(previous) ? previous : ""
  }

  rebuildOptions(allowedValues) {
    const select = this.selectTarget
    select.options.length = 0
    select.add(new Option(this.defaultLabelValue, ""))
    allowedValues.forEach((value) => select.add(new Option(this.labelFor(value), value)))
  }

  labelFor(value) {
    return value.charAt(0).toUpperCase() + value.slice(1)
  }

  announceIfCleared(previous, current) {
    if (!this.hasStatusTarget) return
    if (previous === current || previous === "") return

    this.statusTarget.textContent = "Thinking effort reset to Default — not supported for this model."
  }
}
