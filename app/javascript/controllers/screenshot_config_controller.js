import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "source"]

  async copy() {
    if (!this.hasSourceTarget || !this.hasButtonTarget) return

    const originalText = this.buttonTarget.textContent

    try {
      await window.navigator.clipboard.writeText(this.sourceTarget.textContent || "")
      this.buttonTarget.textContent = "Copied"
      window.setTimeout(() => { this.buttonTarget.textContent = originalText }, 1200)
    } catch {
      this.buttonTarget.textContent = originalText
    }
  }
}
