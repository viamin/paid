import { Controller } from "@hotwired/stimulus"
import Chartkick from "chartkick"

export default class extends Controller {
  static values = {
    type: String,
    data: String,
    options: { type: String, default: "{}" }
  }

  connect() {
    this.renderChart()
  }

  disconnect() {
    this.destroyChart()
  }

  renderChart() {
    this.destroyChart()

    const chartClass = Chartkick[this.typeValue]
    if (!chartClass) return

    this.chart = new chartClass(this.element.id, JSON.parse(this.dataValue), JSON.parse(this.optionsValue))
  }

  destroyChart() {
    const existingChart = this.chart || Chartkick.charts[this.element.id]
    if (!existingChart) return

    existingChart.destroy()
    delete Chartkick.charts[this.element.id]
    this.chart = null
  }
}
