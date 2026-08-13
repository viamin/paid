import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "toggle"]
  static values = { maxLines: { type: Number, default: 10 } }

  connect() {
    this.truncate()
  }

  truncate() {
    const content = this.contentTarget
    const lineHeight = parseFloat(window.getComputedStyle(content).lineHeight)

    if (!lineHeight || isNaN(lineHeight)) return

    const maxHeight = lineHeight * this.maxLinesValue
    const renderedHeight = content.scrollHeight

    if (renderedHeight <= maxHeight) {
      this.toggleTarget.classList.add("hidden")
      return
    }

    this.maxHeight = maxHeight
    this.expanded = false

    content.style.maxHeight = `${maxHeight}px`
    content.style.overflow = "hidden"
    this.updateToggle()
  }

  toggle() {
    this.expanded = !this.expanded
    const content = this.contentTarget

    if (this.expanded) {
      content.style.maxHeight = "none"
      content.style.overflow = "visible"
    } else {
      content.style.maxHeight = `${this.maxHeight}px`
      content.style.overflow = "hidden"
    }
    this.updateToggle()
  }

  updateToggle() {
    this.toggleTarget.textContent = this.expanded ? "Collapse" : "Show more"
    this.toggleTarget.classList.remove("hidden")
  }
}
