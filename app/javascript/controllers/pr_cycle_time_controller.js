import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    frameId: { type: String, default: "dashboard-pr-cycle-time" },
    baseUrl: String,
    mergedCounts: { type: String, default: "{}" }
  }

  connect() {
    this._installTooltipCallback()
  }

  mergedCountsValueChanged() {
    this._installTooltipCallback()
  }

  reloadWithCutoff(event) {
    const cutoff = event.target.value
    const frame = document.getElementById(this.frameIdValue)
    if (!frame) return

    const url = new URL(this.baseUrlValue, window.location.origin)
    url.searchParams.set("outlier_cutoff", cutoff)
    frame.setAttribute("src", url.toString())
  }

  _installTooltipCallback() {
    const chartCanvas = this.element.querySelector("#pr-cycle-time-chart")
    if (!chartCanvas) return

    const chart = Chart.getChart(chartCanvas)
    if (!chart) {
      setTimeout(() => this._installTooltipCallback(), 500)
      return
    }

    const mergedCounts = JSON.parse(this.mergedCountsValue)

    if (!chart.options.plugins.tooltip.callbacks) {
      chart.options.plugins.tooltip.callbacks = {}
    }
    chart.options.plugins.tooltip.callbacks.afterBody = function (tooltipItems) {
      if (!tooltipItems.length) return ""
      const rawDate = tooltipItems[0].label
      if (!rawDate || !/^\d{4}-\d{2}-\d{2}$/.test(rawDate)) return ""
      const count = mergedCounts[rawDate] || 0
      return "Merged PRs: " + count
    }
    chart.update("none")
  }
}
