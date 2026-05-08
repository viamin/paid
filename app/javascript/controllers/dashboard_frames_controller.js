import { Controller } from "@hotwired/stimulus"

// Staggers dashboard turbo-frame loads so the page does not burst several
// concurrent widget requests at once. This keeps the initial dashboard shell
// responsive in constrained environments where Puma only has a few threads.
export default class extends Controller {
  static targets = ["frame"]
  static values = {
    frameDelay: { type: Number, default: 350 },
    initialDelay: { type: Number, default: 0 }
  }

  connect() {
    this.pendingFrames = this.frameTargets.filter((frame) => !frame.getAttribute("src"))
    this.loadNextFrame = this.loadNextFrame.bind(this)
    this.onFrameSettled = this.onFrameSettled.bind(this)

    this.frameTargets.forEach((frame) => {
      frame.addEventListener("turbo:frame-load", this.onFrameSettled)
      frame.addEventListener("turbo:fetch-request-error", this.onFrameSettled)
    })

    this.scheduleNextFrame(this.initialDelayValue)
  }

  disconnect() {
    if (this.timer) {
      window.clearTimeout(this.timer)
      this.timer = null
    }

    this.frameTargets.forEach((frame) => {
      frame.removeEventListener("turbo:frame-load", this.onFrameSettled)
      frame.removeEventListener("turbo:fetch-request-error", this.onFrameSettled)
    })
  }

  scheduleNextFrame(delay = this.frameDelayValue) {
    if (this.pendingFrames.length === 0 || this.currentFrame) return

    this.timer = window.setTimeout(this.loadNextFrame, delay)
  }

  loadNextFrame() {
    this.timer = null
    const frame = this.pendingFrames.shift()
    if (!frame) return

    const src = frame.dataset.dashboardFramesSrc
    if (src) {
      this.currentFrame = frame
      frame.setAttribute("src", src)
    } else {
      this.scheduleNextFrame()
    }
  }

  onFrameSettled(event) {
    if (event.target !== this.currentFrame) return

    this.currentFrame = null
    this.scheduleNextFrame()
  }
}
