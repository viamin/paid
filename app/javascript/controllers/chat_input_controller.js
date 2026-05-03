import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea", "sendButton", "charCount"]

  connect() {
    this.resize()
    this.updateCount()
  }

  send(event) {
    event.preventDefault()
    const content = this.textareaTarget.value.trim()
    if (!content || this.sendButtonTarget.disabled) return

    this.element.dispatchEvent(new window.CustomEvent("chat-input:send", {
      bubbles: true,
      detail: { content }
    }))

    this.textareaTarget.value = ""
    this.resize()
    this.updateCount()
  }

  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.element.requestSubmit()
    }
  }

  resize() {
    const textarea = this.textareaTarget
    textarea.style.height = "0px"
    textarea.style.height = `${Math.min(textarea.scrollHeight, 320)}px`
    this.updateCount()
  }

  disable() {
    this.sendButtonTarget.disabled = true
    this.textareaTarget.disabled = true
  }

  enable() {
    this.sendButtonTarget.disabled = false
    this.textareaTarget.disabled = false
    this.textareaTarget.focus()
  }

  updateCount() {
    if (!this.hasCharCountTarget) return

    this.charCountTarget.textContent = `${this.textareaTarget.value.length} / 12000`
  }
}
