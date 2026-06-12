import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    frameId: { type: String, default: "dashboard-pr-cycle-time" },
    baseUrl: String
  }

  reloadWithCutoff(event) {
    const cutoff = event.target.value
    const frame = document.getElementById(this.frameIdValue)
    if (!frame) return

    const url = new URL(this.baseUrlValue, window.location.origin)
    url.searchParams.set("outlier_cutoff", cutoff)
    frame.setAttribute("src", url.toString())
  }
}
