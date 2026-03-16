import { Controller } from "@hotwired/stimulus"

// Manages the live dashboard page behavior.
// Turbo Streams handle DOM updates; this controller provides
// visual feedback (pulse on the live indicator when updates arrive).
export default class extends Controller {
  connect() {
    this.boundOnStreamRender = this.onStreamRender.bind(this)
    this.element.addEventListener("turbo:before-stream-render", this.boundOnStreamRender)
  }

  disconnect() {
    this.element.removeEventListener("turbo:before-stream-render", this.boundOnStreamRender)
  }

  onStreamRender() {
    const indicator = document.getElementById("live-indicator")
    if (indicator) {
      indicator.classList.add("scale-125")
      window.setTimeout(() => indicator.classList.remove("scale-125"), 300)
    }
  }
}
