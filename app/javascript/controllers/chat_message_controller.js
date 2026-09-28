import { Controller } from "@hotwired/stimulus"
import hljs from "highlight.js/lib/common"
import { renderMarkdown } from "../lib/safe_markdown"

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

    // @spec CHAT-API-016
    const rawContent = this.visibleContent(this.contentTarget.dataset.rawContent || "")

    try {
      this.disablePlainTextFallback()
      this.contentTarget.innerHTML = renderMarkdown(rawContent)

      this.decorateCodeBlocks()
    } catch {
      this.enablePlainTextFallback()
      this.contentTarget.textContent = rawContent
    }
  }

  visibleContent(rawContent) {
    const openingTag = "<think>"
    if (openingTag.startsWith(rawContent)) return ""
    if (!rawContent.startsWith(openingTag)) return rawContent

    const closingTag = "</think>"
    const end = rawContent.indexOf(closingTag)
    return end < 0 ? "" : rawContent.slice(end + closingTag.length).trimStart()
  }

  // @spec CHAT-API-021
  async copyCode(event) {
    const button = event.currentTarget
    const originalText = button.textContent
    const content = button.dataset.copyContent || ""

    try {
      await this.writeToClipboard(content)
      this.flashButton(button, "Copied", originalText, 1200)
    } catch (error) {
      this.flashButton(button, "Copy failed", originalText, 1600)
      this.reportCopyFailure(error)
    }
  }

  async writeToClipboard(content) {
    if (this.canUseClipboardApi()) {
      try {
        await window.navigator.clipboard.writeText(content)
        return
      } catch (clipboardError) {
        // Insecure context, sandboxed iframe, denied permission, or a
        // synchronous clipboard failure all land here. Fall through to the
        // execCommand path so users still get a working button instead of
        // a silent no-op (#4070).
        try {
          this.legacyCopy(content)
          return
        } catch (fallbackError) {
          const error = new Error(
            "clipboard.writeText and execCommand both failed: " +
            `${clipboardError.message} / ${fallbackError.message}`
          )
          error.cause = fallbackError
          throw error
        }
      }
    }

    this.legacyCopy(content)
  }

  canUseClipboardApi() {
    return typeof window !== "undefined"
      && typeof window.navigator !== "undefined"
      && !!window.navigator.clipboard
      && typeof window.navigator.clipboard.writeText === "function"
  }

  legacyCopy(content) {
    if (typeof document === "undefined") {
      throw new Error("document is unavailable; cannot run execCommand fallback")
    }

    const textarea = document.createElement("textarea")
    textarea.value = content
    textarea.setAttribute("readonly", "")
    textarea.dataset.chatMessageCopyFallback = "true"
    textarea.style.position = "fixed"
    textarea.style.top = "0"
    textarea.style.left = "0"
    textarea.style.opacity = "0"
    textarea.style.pointerEvents = "none"

    const previouslyFocused = document.activeElement
    document.body.appendChild(textarea)
    textarea.select()

    try {
      if (document.execCommand("copy") !== true) {
        throw new Error("document.execCommand('copy') returned false")
      }
    } finally {
      document.body.removeChild(textarea)
      if (previouslyFocused && typeof previouslyFocused.focus === "function") {
        previouslyFocused.focus()
      }
    }
  }

  flashButton(button, message, originalText, restoreDelayMs) {
    button.textContent = message
    window.setTimeout(() => { button.textContent = originalText }, restoreDelayMs)
  }

  reportCopyFailure(error) {
    if (typeof window === "undefined" || !window.console) return

    const consoleLike = window.console
    if (typeof consoleLike.warn === "function") {
      consoleLike.warn("chat-message#copyCode: clipboard write failed", error)
    } else if (typeof consoleLike.error === "function") {
      consoleLike.error("chat-message#copyCode: clipboard write failed", error)
    }
  }

  decorateCodeBlocks() {
    this.contentTarget.querySelectorAll("pre > code").forEach((codeBlock) => {
      if (codeBlock.closest("[data-code-block-wrapper]")) return

      try {
        hljs.highlightElement(codeBlock)
      } catch {
        // Keep the raw code visible if syntax highlighting cannot classify it.
      }

      const pre = codeBlock.parentElement
      const language = [...codeBlock.classList].find((name) => name.startsWith("language-"))?.replace("language-", "") || "text"
      const lines = codeBlock.textContent.split("\n")

      const wrapper = document.createElement("div")
      wrapper.dataset.codeBlockWrapper = "true"
      wrapper.className = "my-4 overflow-hidden rounded-2xl border border-slate-200 bg-slate-950 text-slate-100 shadow-sm"

      const header = document.createElement("div")
      header.className = "flex items-center justify-between border-b border-slate-800 px-4 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-slate-400"
      const languageLabel = document.createElement("span")
      languageLabel.textContent = language
      header.append(languageLabel)

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
      lines.forEach((_, index) => {
        const lineNum = document.createElement("div")
        lineNum.textContent = index + 1
        gutter.append(lineNum)
      })

      pre.className = "overflow-x-auto bg-transparent px-4 py-4 text-sm leading-6"
      codeBlock.classList.add("block", "min-w-full", "bg-transparent", "font-mono")

      pre.replaceWith(wrapper)
      wrapper.append(header, body)
      body.append(gutter, pre)
    })
  }

  enablePlainTextFallback() {
    this.contentTarget.classList.add("whitespace-pre-wrap", "break-words")
  }

  disablePlainTextFallback() {
    this.contentTarget.classList.remove("whitespace-pre-wrap", "break-words")
  }
}
