import { Controller } from "@hotwired/stimulus"

// Composes the click-to-answer widget's answer into the hidden answers[]
// input as human-readable lines the server can validate:
//   <option line>            per selected option (e.g. "SQLite (local file)"),
//   "Other: <detail text>"   when the Other pill is selected,
//   "Details: <detail text>" appended when detail text is present without
//                            Other.
// On connect it restores the widget state from the hidden input's serialized
// value (pending-answer prefill after a failure redirect re-selects the
// chosen pills and repopulates the detail textarea instead of dumping the
// serialized answer into a textarea).
// @spec OPERATOR-INBOX-012
export default class extends Controller {
  static targets = ["option", "other", "detail", "composed"]

  connect() {
    this.restore()
  }

  compose() {
    const lines = this.selectedOptions().map(input => input.dataset.clarifyingChoiceLine)
    // Collapse whitespace: the composed value is a line-based format, so a
    // multi-line detail entry would otherwise forge extra answer lines.
    const detail = this.detailTarget.value.replace(/\s+/g, " ").trim()
    const otherSelected = this.otherSelected()

    if (otherSelected) {
      lines.push(`Other: ${detail}`)
    } else if (detail.length > 0) {
      lines.push(`Details: ${detail}`)
    }

    this.composedTarget.value = lines.join("\n")
    this.detailTarget.required = otherSelected
    // Bubble an input event so surface controllers (the wizard's progress
    // tracker) observe programmatic updates to the hidden answers[] input.
    this.composedTarget.dispatchEvent(new window.Event("input", { bubbles: true }))
  }

  restore() {
    const lines = this.composedTarget.value.split("\n").map(line => line.trim()).filter(line => line.length > 0)
    const otherLine = lines.find(line => line.startsWith("Other:"))
    const detailsLine = otherLine ? null : lines.find(line => line.startsWith("Details:"))
    const selections = new Set(lines)
    selections.delete(otherLine)
    selections.delete(detailsLine)

    this.optionTargets.forEach(input => {
      input.checked = selections.has(input.dataset.clarifyingChoiceLine)
    })
    this.otherTargets.forEach(input => {
      input.checked = Boolean(otherLine)
    })
    this.detailTarget.value = otherLine ? detailText(otherLine, "Other:") : detailText(detailsLine, "Details:")

    this.compose()
  }

  selectedOptions() {
    return this.optionTargets.filter(input => input.checked)
  }

  otherSelected() {
    return this.otherTargets.some(input => input.checked)
  }
}

function detailText(line, marker) {
  if (!line) return ""

  return line.slice(marker.length).trim()
}
