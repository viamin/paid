import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Manages drag-and-drop reordering of provider priority list.
// Updates hidden input fields with the JSON array of provider names
// and the list of providers enabled for fallback.
export default class extends Controller {
  static targets = ["list", "item", "input", "enabledInput", "checkbox"]

  connect() {
    if (!this.hasListTarget) return

    this.sortable = Sortable.create(this.listTarget, {
      animation: 150,
      ghostClass: "opacity-50",
      handle: ".drag-handle",
      filter: "input",
      preventOnFilter: false,
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

  toggleFallback(event) {
    const checkbox = event.target
    const item = checkbox.closest("[data-sortable-target='item']")
    const enabled = checkbox.checked

    item.dataset.fallbackEnabled = enabled

    if (enabled) {
      item.classList.remove("bg-gray-50", "opacity-60")
      item.classList.add("bg-white")
      const nameSpan = item.querySelector("span.text-sm")
      if (nameSpan) {
        nameSpan.classList.remove("text-gray-400")
        nameSpan.classList.add("text-gray-900")
      }
    } else {
      item.classList.remove("bg-white")
      item.classList.add("bg-gray-50", "opacity-60")
      const nameSpan = item.querySelector("span.text-sm")
      if (nameSpan) {
        nameSpan.classList.remove("text-gray-900")
        nameSpan.classList.add("text-gray-400")
      }
    }

    this.updateInput()
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

    // Update the enabled fallback providers hidden field
    if (this.hasEnabledInputTarget) {
      const enabledProviders = this.itemTargets
        .filter(el => el.dataset.fallbackEnabled === "true")
        .map(el => el.dataset.provider)

      this.enabledInputTarget.value = JSON.stringify(enabledProviders)
    }
  }
}
