import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "searchInput", "card", "modal", "mobileMenu", "mobileButton", "mobileOpenLabel", "mobileCloseLabel"]
  static values = { activeSessionId: Number }

  connect() {
    this.mediaQuery = window.matchMedia("(min-width: 1024px)")
    this.boundCloseOnDesktop = this.closeOnDesktop.bind(this)
    this.boundCloseOnNavigate = this.closeSidebar.bind(this)

    this.mediaQuery.addEventListener("change", this.boundCloseOnDesktop)
    document.addEventListener("turbo:before-visit", this.boundCloseOnNavigate)

    this.observer = new window.MutationObserver(() => {
      this.filter()
      this.updateActiveCard()
    })
    this.observer.observe(this.listTarget, { childList: true, subtree: true })
    this.filter()
    this.updateActiveCard()
    this.updateMobileSidebarState()
  }

  disconnect() {
    this.observer?.disconnect()
    this.mediaQuery.removeEventListener("change", this.boundCloseOnDesktop)
    document.removeEventListener("turbo:before-visit", this.boundCloseOnNavigate)
    document.body.classList.remove("overflow-hidden")
  }

  filter() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.trim().toLowerCase() : ""
    this.cardTargets.forEach((card) => {
      const matches = !query || card.dataset.searchText.includes(query)
      card.classList.toggle("hidden", !matches)
    })
  }

  openModal() {
    this.closeSidebar()
    this.modalTarget.showModal()
  }

  closeModal() {
    this.modalTarget.close()
  }

  toggleSidebar() {
    this.setSidebarOpen(this.mobileMenuTarget.classList.contains("hidden"))
  }

  closeSidebar() {
    this.setSidebarOpen(false)
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

  closeOnDesktop(event) {
    if (event.matches) this.closeSidebar()
  }

  setSidebarOpen(open) {
    if (!this.hasMobileMenuTarget) return

    this.mobileMenuTarget.classList.toggle("hidden", !open)
    this.updateMobileSidebarState(open)
  }

  updateMobileSidebarState(forceOpen = null) {
    if (!this.hasMobileMenuTarget) return

    const open = forceOpen === null ? !this.mobileMenuTarget.classList.contains("hidden") : forceOpen
    const isDesktop = this.mediaQuery.matches
    const mobileOpen = open && !isDesktop

    // On desktop the sidebar is always visible (lg:block), so never hide it from screen readers.
    const ariaHidden = isDesktop ? false : !mobileOpen
    this.mobileMenuTarget.setAttribute("aria-hidden", ariaHidden.toString())
    document.body.classList.toggle("overflow-hidden", mobileOpen)

    if (this.hasMobileButtonTarget) {
      this.mobileButtonTarget.setAttribute("aria-expanded", mobileOpen.toString())
    }

    if (this.hasMobileOpenLabelTarget) {
      this.mobileOpenLabelTarget.classList.toggle("hidden", mobileOpen)
    }

    if (this.hasMobileCloseLabelTarget) {
      this.mobileCloseLabelTarget.classList.toggle("hidden", !mobileOpen)
    }
  }
}
