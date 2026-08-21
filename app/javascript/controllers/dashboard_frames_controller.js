import { Controller } from "@hotwired/stimulus"

// @spec DASHBOARD-FRAME-CACHE-001..007 — docs/intent/dashboard-frame-caching/
// Bump the version when tile markup shape changes so stale entries are ignored.
const CACHE_PREFIX = "dashboard-frame:v1"
const STALE_CLASS = "opacity-60"
// Applied while a frame shows cached content, removed when fresh content
// loads. Kept on fetch errors — the content is still stale.
const STALE_CLASSES = [STALE_CLASS, "transition-opacity"]

// Staggers dashboard turbo-frame loads so the page does not burst several
// concurrent widget requests at once. This keeps the initial dashboard shell
// responsive in constrained environments where Puma only has a few threads.
//
// Also acts as a stale-while-revalidate cache: on connect each deferred frame
// is instantly hydrated from sessionStorage (skeleton only on a cache miss),
// then revalidated through the normal staggered load. Cached HTML keeps its
// data-controller attributes, so Stimulus's MutationObserver reconnects any
// child controllers (e.g. pr-cycle-time charts) automatically.
export default class extends Controller {
  static targets = ["frame"]
  static values = {
    cacheScope: String,
    frameDelay: { type: Number, default: 350 },
    initialDelay: { type: Number, default: 0 }
  }

  connect() {
    this.pendingFrames = this.frameTargets.filter((frame) => {
      if (frame.getAttribute("src")) {
        // Turbo snapshot restore (back navigation) or a live stream already
        // gave this frame content — keep it as rendered, skip the cache.
        frame.classList.remove(...STALE_CLASSES)
        return false
      }
      this.hydrateFromCache(frame)
      return true
    })
    this.loadNextFrame = this.loadNextFrame.bind(this)
    this.onFrameSettled = this.onFrameSettled.bind(this)
    this.onFrameMissing = this.onFrameMissing.bind(this)

    this.frameTargets.forEach((frame) => {
      frame.addEventListener("turbo:frame-load", this.onFrameSettled)
      frame.addEventListener("turbo:fetch-request-error", this.onFrameSettled)
      frame.addEventListener("turbo:frame-missing", this.onFrameMissing)
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
      frame.removeEventListener("turbo:frame-missing", this.onFrameMissing)
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

    if (event.type === "turbo:frame-load") {
      event.target.classList.remove(...STALE_CLASSES)
      this.cacheFrame(event.target)
    }
    this.currentFrame = null
    this.scheduleNextFrame()
  }

  // HTTP errors and expired-session redirects render a page without the
  // matching frame, so Turbo fires frame-missing instead of frame-load or
  // fetch-request-error. Keep already-cached stale content when present,
  // otherwise let Turbo show its own fallback — and always release the queue.
  onFrameMissing(event) {
    if (event.target !== this.currentFrame) return

    if (event.target.classList.contains(STALE_CLASS)) event.preventDefault()
    this.currentFrame = null
    this.scheduleNextFrame()
  }

  cacheKey(frame) {
    return `${CACHE_PREFIX}:${this.cacheScopeValue}:${frame.id}:${frame.dataset.dashboardFramesSrc}`
  }

  // sessionStorage can throw (private mode, quota) — degrade to skeletons.
  // The scope value (account + user id) keeps per-user tiles such as the
  // queue preview from hydrating for a different user of the same account.
  hydrateFromCache(frame) {
    if (!this.cacheScopeValue) return

    try {
      const html = window.sessionStorage.getItem(this.cacheKey(frame))
      if (html) {
        frame.innerHTML = html
        frame.classList.add(...STALE_CLASSES)
      }
    } catch {
      // ignore
    }
  }

  cacheFrame(frame) {
    if (!this.cacheScopeValue) return
    // Only cache the response to the frame's own deferred src — never an
    // in-frame navigation (filter links, cancel forms) that changed the URL.
    if (frame.getAttribute("src") !== frame.dataset.dashboardFramesSrc) return

    try {
      window.sessionStorage.setItem(this.cacheKey(frame), frame.innerHTML)
    } catch {
      // ignore
    }
  }
}
