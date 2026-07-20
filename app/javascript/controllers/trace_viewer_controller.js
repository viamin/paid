import { Controller } from "@hotwired/stimulus"

// Enhances the embedded Playwright Trace Viewer iframe with a loading
// indicator. The interactive scrubbing/DOM/network/console inspection is
// provided by the trace viewer app itself (loaded inside the iframe); this
// controller only manages the loading affordance while the viewer boots.
export default class extends Controller {
  static targets = ["frame", "loading"]

  connect() {
    this.showLoading()
  }

  loaded() {
    this.hideLoading()
  }

  showLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.classList.remove("hidden")
  }

  hideLoading() {
    if (this.hasLoadingTarget) this.loadingTarget.classList.add("hidden")
  }
}
