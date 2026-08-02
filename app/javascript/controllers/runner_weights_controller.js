import { Controller } from "@hotwired/stimulus"

// @spec RUNNER-WEIGHTS-001
// Keeps the manual runner weight inputs and the read-only notice in sync
// with the "Auto-balance weights based on usage quotas" checkbox, without
// waiting for a form submit/re-render round trip.
export default class extends Controller {
  static targets = ["autoWeight", "weight", "notice"]

  toggle() {
    const auto = this.autoWeightTarget.checked

    this.weightTargets.forEach((el) => {
      el.disabled = auto
    })
    this.noticeTargets.forEach((el) => {
      el.hidden = !auto
    })
  }
}
