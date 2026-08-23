import { marked } from "marked"

const SAFE_URL_SCHEMES = /^(https?|mailto):/i

function escapeAttribute(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
}

function escapeHtml(content) {
  return content
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
}

function createSafeRenderer() {
  const renderer = new marked.Renderer()

  renderer.link = function ({ href, tokens, text }) {
    const label = tokens ? this.parser.parseInline(tokens) : text
    if (!href) return label
    if (!SAFE_URL_SCHEMES.test(href)) return label
    return `<a href="${escapeAttribute(href)}" rel="noopener noreferrer">${label}</a>`
  }

  renderer.image = ({ text }) => text || ""

  return renderer
}

const safeRenderer = createSafeRenderer()

// Escapes raw HTML and parses the result as markdown using a renderer that
// restricts links to SAFE_URL_SCHEMES and strips images. Pass `inline: true`
// to render a single line of markdown (no block-level elements) - useful for
// headings or other contexts where wrapping the output in a <p> or other
// block element would be invalid or visually incorrect.
function renderMarkdown(rawContent, { inline = false } = {}) {
  const safeContent = escapeHtml(rawContent)
  const options = { breaks: true, gfm: true, renderer: safeRenderer }

  return inline ? marked.parseInline(safeContent, options) : marked.parse(safeContent, options)
}

export { SAFE_URL_SCHEMES, escapeHtml, renderMarkdown }
