import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "toggle"]
  static values = { maxLines: { type: Number, default: 10 } }

  connect() {
    this.truncate()
  }

  truncate() {
    const content = this.contentTarget
    const fullText = content.textContent
    const lines = fullText.split("\n")

    if (lines.length <= this.maxLinesValue) {
      this.toggleTarget.classList.add("hidden")
      return
    }

    this.fullText = fullText
    this.truncatedText = lines.slice(0, this.maxLinesValue).join("\n")
    this.expanded = false
    this.totalLines = lines.length

    content.textContent = this.truncatedText
    this.updateToggle()
  }

  toggle() {
    this.expanded = !this.expanded
    this.contentTarget.textContent = this.expanded ? this.fullText : this.truncatedText
    this.updateToggle()
  }

  updateToggle() {
    const hiddenCount = this.totalLines - this.maxLinesValue
    this.toggleTarget.textContent = this.expanded
      ? "Collapse"
      : `Show ${hiddenCount} more line${hiddenCount === 1 ? "" : "s"}`
    this.toggleTarget.classList.remove("hidden")
  }
}
