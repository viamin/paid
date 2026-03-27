import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.boundOnStreamRender = this.onStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundOnStreamRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.boundOnStreamRender)
  }

  onStreamRender() {
    const indicator = document.getElementById("live-indicator")
    if (!indicator) return

    indicator.classList.add("scale-125")
    window.setTimeout(() => indicator.classList.remove("scale-125"), 300)
  }
}
