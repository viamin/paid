import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "../lib/safe_markdown"

// Renders a small amount of inline markdown (bold/italic, inline code,
// links) inside an arbitrary element, falling back to the original plain
// text if parsing fails. Intended for single-line content such as headings
// where block-level markdown (lists, paragraphs) would be inappropriate.
export default class extends Controller {
  static values = { content: String }

  connect() {
    this.render()
  }

  render() {
    const rawContent = this.contentValue

    try {
      this.element.classList.remove("whitespace-pre-wrap", "break-words")
      this.element.innerHTML = renderMarkdown(rawContent, { inline: true })
    } catch {
      this.element.classList.add("whitespace-pre-wrap", "break-words")
      this.element.textContent = rawContent
    }
  }
}
