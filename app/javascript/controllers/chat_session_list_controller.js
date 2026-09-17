import { Controller } from "@hotwired/stimulus"

// Manages the chat session list (sidebar) on `/chat` and `/chat/:id`:
// filters cards by search input, applies the shared active-row class
// (LIST-DETAIL-003) when the card is the currently selected session,
// and opens / closes the mobile overlay drawer. The shared class set
// is sourced from `data-active-classes` on each card so a future
// change to the active-row treatment lives in
// `MasterDetailLayoutHelper#master_detail_active_row_classes`, not here.
export default class extends Controller {
  static targets = ["list", "searchInput", "card", "modal", "mobileMenu", "mobileButton", "mobileOpenLabel", "mobileCloseLabel"]
  static values = { activeSessionId: Number }

  connect() {
    this.mediaQuery = typeof window.matchMedia === "function" ? window.matchMedia("(min-width: 1024px)") : null
    this.boundCloseOnDesktop = this.closeOnDesktop.bind(this)
    this.boundCloseOnNavigate = this.closeSidebar.bind(this)
    this.boundOnFrameRender = this.handleFrameRender.bind(this)

    this.addMediaQueryListener(this.boundCloseOnDesktop)
    document.addEventListener("turbo:before-visit", this.boundCloseOnNavigate)
    this.element.addEventListener("turbo:frame-render", this.boundOnFrameRender)

    this.setupObserver()
    this.filter()
    this.updateActiveCard()
    this.updateMobileSidebarState()
  }

  disconnect() {
    this.observer?.disconnect()
    this.removeMediaQueryListener(this.boundCloseOnDesktop)
    document.removeEventListener("turbo:before-visit", this.boundCloseOnNavigate)
    this.element.removeEventListener("turbo:frame-render", this.boundOnFrameRender)
    document.body.classList.remove("overflow-hidden")
  }

  setupObserver() {
    this.observer?.disconnect()
    if (!this.hasListTarget) return

    this.observer = new window.MutationObserver(() => {
      this.filter()
      this.updateActiveCard()
    })
    this.observer.observe(this.listTarget, { childList: true, subtree: true })
  }

  handleFrameRender(event) {
    const targetId = event.target?.id
    if (targetId !== "chat_sessions_list") return

    this.setupObserver()
    this.filter()
    this.updateActiveCard()
  }

  filter() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.trim().toLowerCase() : ""
    this.cardTargets.forEach((card) => {
      const matches = !query || card.dataset.searchText.includes(query)
      card.classList.toggle("hidden", !matches)
    })
  }

  openModal() {
    if (!this.hasModalTarget) return

    this.closeSidebar()
    this.modalTarget.showModal()
  }

  closeModal() {
    if (!this.hasModalTarget) return

    this.modalTarget.close()
  }

  toggleSidebar() {
    if (!this.hasMobileMenuTarget) return

    this.setSidebarOpen(this.mobileMenuTarget.classList.contains("hidden"))
  }

  closeSidebar() {
    this.setSidebarOpen(false)
  }

  updateActiveCard() {
    const activeId = this.currentSessionId()

    this.cardTargets.forEach((card) => {
      const selected = Number(card.dataset.sessionId) === activeId
      const activeClasses = (card.dataset.activeClasses || "").split(/\s+/).filter(Boolean)
      activeClasses.forEach((cls) => card.classList.toggle(cls, selected))
      // `_session_card` paints `hover:bg-gray-50` on every card at render
      // time. Keep it mutually exclusive with the active-row class set —
      // the same treatment as `inbox-master-detail#highlightRow` — so
      // hovering the selected card doesn't gray out the indigo selection
      // and a just-deselected card gets its hover affordance back.
      card.classList.toggle("hover:bg-gray-50", !selected)
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

  addMediaQueryListener(listener) {
    if (!this.mediaQuery) return

    if (typeof this.mediaQuery.addEventListener === "function") {
      this.mediaQuery.addEventListener("change", listener)
      return
    }

    if (typeof this.mediaQuery.addListener === "function") {
      this.mediaQuery.addListener(listener)
    }
  }

  removeMediaQueryListener(listener) {
    if (!this.mediaQuery) return

    if (typeof this.mediaQuery.removeEventListener === "function") {
      this.mediaQuery.removeEventListener("change", listener)
      return
    }

    if (typeof this.mediaQuery.removeListener === "function") {
      this.mediaQuery.removeListener(listener)
    }
  }

  setSidebarOpen(open) {
    if (!this.hasMobileMenuTarget) return

    this.mobileMenuTarget.classList.toggle("hidden", !open)
    this.updateMobileSidebarState(open)
  }

  updateMobileSidebarState(forceOpen = null) {
    if (!this.hasMobileMenuTarget) return

    const open = forceOpen === null ? !this.mobileMenuTarget.classList.contains("hidden") : forceOpen
    const isDesktop = this.mediaQuery?.matches ?? false
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
