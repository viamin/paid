import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "../lib/safe_markdown"

// Renders a small amount of markdown inside an arbitrary element, falling
// back to the original plain text if parsing fails. Defaults to inline
// markdown (bold/italic, inline code, links) for single-line content such
// as headings where block-level markdown (lists, paragraphs) would be
// inappropriate. Pass `markdown-text-block-value="true"` to switch to
// block-level rendering for multi-paragraph content (e.g. the
// clarifying-questions context panel).
export default class extends Controller {
  static values = { content: String, block: Boolean }

  connect() {
    this.render()
  }

  contentValueChanged() {
    this.render()
  }

  render() {
    const rawContent = this.contentValue

    try {
      this.element.classList.remove("whitespace-pre-wrap", "break-words")
      this.element.innerHTML = renderMarkdown(rawContent, { inline: !this.blockValue })
    } catch {
      this.element.classList.add("whitespace-pre-wrap", "break-words")
      this.element.textContent = rawContent
    }
  }
}
