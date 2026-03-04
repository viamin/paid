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
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
  }

  updateInput() {
    if (!this.hasInputTarget) return

    // Get all providers from the sorted list
    const providers = this.itemTargets.map(el => el.dataset.provider)

    // Skip the first one (primary provider) and store the rest as fallbacks
    const fallbacks = providers.slice(1)

    this.inputTarget.value = JSON.stringify(fallbacks)
  }
}
