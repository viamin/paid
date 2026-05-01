import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "searchInput", "card", "modal"]
  static values = { activeSessionId: Number }

  connect() {
    this.observer = new window.MutationObserver(() => {
      this.filter()
      this.updateActiveCard()
    })
    this.observer.observe(this.listTarget, { childList: true, subtree: true })
    this.filter()
    this.updateActiveCard()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  filter() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.trim().toLowerCase() : ""
    this.cardTargets.forEach((card) => {
      const matches = !query || card.dataset.searchText.includes(query)
      card.classList.toggle("hidden", !matches)
    })
  }

  openModal() {
    this.modalTarget.showModal()
  }

  closeModal() {
    this.modalTarget.close()
  }

  updateActiveCard() {
    const activeId = this.currentSessionId()

    this.cardTargets.forEach((card) => {
      const selected = Number(card.dataset.sessionId) === activeId
      card.classList.toggle("border-sky-400", selected)
      card.classList.toggle("bg-sky-50", selected)
      card.classList.toggle("shadow-md", selected)
    })
  }

  currentSessionId() {
    if (this.hasActiveSessionIdValue && this.activeSessionIdValue) return this.activeSessionIdValue

    const match = window.location.pathname.match(/\/chat\/(\d+)/)
    return match ? Number(match[1]) : null
  }
}
