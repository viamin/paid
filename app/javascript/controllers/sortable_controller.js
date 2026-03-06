import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Manages drag-and-drop reordering of provider priority list.
// Updates a hidden input field with the JSON array of provider names.
export default class extends Controller {
  static targets = ["list", "item", "input"]

  connect() {
    if (!this.hasListTarget) return

    this.sortable = Sortable.create(this.listTarget, {
      animation: 150,
      ghostClass: "opacity-50",
      handle: ".provider-item",
      onEnd: () => this.updateInput()
    })

    // Initialize the input with current order (excluding primary)
    this.updateInput()

    this.primarySelect = document.getElementById("user_setting_default_agent_provider")
    if (this.primarySelect) {
      this.boundPrimaryChange = () => this.updateInput()
      this.primarySelect.addEventListener("change", this.boundPrimaryChange)
    }
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }

    if (this.primarySelect && this.boundPrimaryChange) {
      this.primarySelect.removeEventListener("change", this.boundPrimaryChange)
    }
  }

  updateInput() {
    if (!this.hasInputTarget) return

    // Get all providers from the sorted list
    const providers = this.itemTargets.map(el => el.dataset.provider)

    // Exclude the configured primary provider by name, not by position.
    const primaryProvider = this.primarySelect?.value || this.inputTarget.dataset.primaryProvider
    const fallbacks = primaryProvider
      ? providers.filter(provider => provider !== primaryProvider)
      : providers.slice(1)

    this.inputTarget.value = JSON.stringify(fallbacks)
  }
}
