import { Controller } from "@hotwired/stimulus"
import { marked } from "marked"
import hljs from "highlight.js/lib/common"

export default class extends Controller {
  static targets = ["content"]
  static values = { role: String, markdown: Boolean }

  connect() {
    this.render()
  }

  appendContent(chunk) {
    if (!this.hasContentTarget) return

    this.contentTarget.dataset.rawContent = `${this.contentTarget.dataset.rawContent || ""}${chunk}`
    this.render()
  }

  render() {
    if (!this.markdownValue || !this.hasContentTarget) return

    const rawContent = this.contentTarget.dataset.rawContent || ""
    const safeContent = this.escapeHtml(rawContent)
    this.contentTarget.innerHTML = marked.parse(safeContent, {
      breaks: true,
      gfm: true
    })

    this.decorateCodeBlocks()
  }

  copyCode(event) {
    const button = event.currentTarget
    window.navigator.clipboard.writeText(button.dataset.copyContent || "")
    button.textContent = "Copied"
    window.setTimeout(() => { button.textContent = "Copy" }, 1200)
  }

  decorateCodeBlocks() {
    this.contentTarget.querySelectorAll("pre > code").forEach((codeBlock) => {
      if (codeBlock.closest("[data-code-block-wrapper]")) return

      hljs.highlightElement(codeBlock)

      const pre = codeBlock.parentElement
      const language = [...codeBlock.classList].find((name) => name.startsWith("language-"))?.replace("language-", "") || "text"
      const lines = codeBlock.textContent.split("\n")

      const wrapper = document.createElement("div")
      wrapper.dataset.codeBlockWrapper = "true"
      wrapper.className = "my-4 overflow-hidden rounded-2xl border border-slate-200 bg-slate-950 text-slate-100 shadow-sm"

      const header = document.createElement("div")
      header.className = "flex items-center justify-between border-b border-slate-800 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-slate-400"
      header.innerHTML = `<span>${language}</span>`

      const copyButton = document.createElement("button")
      copyButton.type = "button"
      copyButton.className = "rounded-full bg-white/10 px-3 py-1 text-[0.65rem] font-semibold text-slate-200 transition hover:bg-white/20"
      copyButton.textContent = "Copy"
      copyButton.dataset.action = "chat-message#copyCode"
      copyButton.dataset.copyContent = codeBlock.textContent
      header.append(copyButton)

      const body = document.createElement("div")
      body.className = "grid grid-cols-[auto_minmax(0,1fr)]"

      const gutter = document.createElement("div")
      gutter.className = "select-none border-r border-slate-800 bg-slate-900/70 px-3 py-4 text-right text-xs leading-6 text-slate-500"
      gutter.innerHTML = lines.map((_, index) => `<div>${index + 1}</div>`).join("")

      pre.className = "overflow-x-auto bg-transparent px-4 py-4 text-sm leading-6"
      codeBlock.classList.add("block", "min-w-full", "bg-transparent", "font-mono")

      pre.replaceWith(wrapper)
      wrapper.append(header, body)
      body.append(gutter, pre)
    })
  }

  escapeHtml(content) {
    return content
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
  }
}
