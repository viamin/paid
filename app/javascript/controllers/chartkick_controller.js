import { Controller } from "@hotwired/stimulus"
import Chartkick from "chartkick"

export default class extends Controller {
  static values = {
    type: String,
    data: String,
    options: { type: String, default: "{}" }
  }

  initialize() {
    this.handleThemeChange = this.renderChart.bind(this)
  }

  connect() {
    window.addEventListener("theme:changed", this.handleThemeChange)
    this.renderChart()
  }

  disconnect() {
    window.removeEventListener("theme:changed", this.handleThemeChange)
    this.destroyChart()
  }

  renderChart() {
    this.destroyChart()

    const chartClass = Chartkick[this.typeValue]
    if (!chartClass) return

    const options = this.resolveThemeTokens(JSON.parse(this.optionsValue))
    this.chart = new chartClass(this.element.id, JSON.parse(this.dataValue), options)
  }

  destroyChart() {
    const existingChart = this.chart || Chartkick.charts[this.element.id]
    if (!existingChart) return

    existingChart.destroy()
    delete Chartkick.charts[this.element.id]
    this.chart = null
  }

  resolveThemeTokens(value) {
    if (Array.isArray(value)) {
      return value.map((entry) => this.resolveThemeTokens(entry))
    }

    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.entries(value).map(([key, entry]) => [key, this.resolveThemeTokens(entry)])
      )
    }

    if (typeof value === "string") {
      return this.resolveThemeToken(value)
    }

    return value
  }

  resolveThemeToken(value) {
    const match = value.match(/^var\((--[^)]+)\)$/)
    if (!match) return value

    const resolved = getComputedStyle(document.documentElement).getPropertyValue(match[1]).trim()
    return resolved || value
  }
}
