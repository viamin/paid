import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "content", "panel"]
  static values = {
    accountId: Number,
    context: Object,
    createUrl: String,
    panelUrlTemplate: String
  }

  connect() {
    this.state = this.readState()
    this.loading = false
    this.renderState()

    if (this.state.open) {
      this.loadPanel()
    }
  }

  toggle() {
    this.state.open = !this.state.open
    this.writeState()
    this.renderState()

    if (this.state.open) {
      this.loadPanel()
    }
  }

  close() {
    this.state.open = false
    this.writeState()
    this.renderState()
  }

  async loadPanel() {
    if (this.loading) return

    this.loading = true
    this.contentTarget.innerHTML = this.loadingMarkup()

    try {
      let sessionId = this.state.sessionId

      if (sessionId) {
        const updated = await this.updateSession(sessionId)
        if (!updated) sessionId = null
      }

      if (!sessionId) {
        sessionId = await this.createSession()
        this.state.sessionId = sessionId
        this.writeState()
      }

      await this.renderPanel(sessionId)
    } catch (error) {
      this.contentTarget.innerHTML = this.errorMarkup()
      window.console.error("chat popup failed", error)
    } finally {
      this.loading = false
    }
  }

  async newChat(event) {
    event?.preventDefault()
    if (this.loading) return

    const previousSessionId = this.state.sessionId

    this.loading = true
    this.contentTarget.innerHTML = this.loadingMarkup()

    try {
      const sessionId = await this.createSession()
      this.state.sessionId = sessionId
      this.writeState()
      await this.renderPanel(sessionId)
    } catch (error) {
      this.state.sessionId = previousSessionId
      this.writeState()
      this.contentTarget.innerHTML = this.errorMarkup()
      window.console.error("chat popup failed", error)
    } finally {
      this.loading = false
    }
  }

  async createSession() {
    const response = await window.fetch(this.createUrlValue, {
      method: "POST",
      headers: this.jsonHeaders(),
      credentials: "same-origin",
      body: JSON.stringify({
        mode: "api",
        project_id: this.contextValue.project_id,
        metadata: {
          entry_point: "popup",
          page_context: this.contextValue
        }
      })
    })

    if (!response.ok) throw new Error(`Create request failed with ${response.status}`)

    const payload = await response.json()
    return payload.id
  }

  async updateSession(sessionId) {
    const response = await window.fetch(this.sessionUrl(sessionId), {
      method: "PATCH",
      headers: this.jsonHeaders(),
      credentials: "same-origin",
      body: JSON.stringify({
        project_id: this.contextValue.project_id,
        metadata: {
          entry_point: "popup",
          page_context: this.contextValue
        }
      })
    })

    return response.ok
  }

  async renderPanel(sessionId) {
    const response = await window.fetch(this.panelUrl(sessionId), {
      headers: { Accept: "text/html" },
      credentials: "same-origin"
    })

    if (!response.ok) throw new Error(`Panel request failed with ${response.status}`)

    this.contentTarget.innerHTML = await response.text()
  }

  jsonHeaders() {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    return {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": csrfToken
    }
  }

  panelUrl(sessionId) {
    return this.panelUrlTemplateValue.replace("__SESSION_ID__", String(sessionId))
  }

  sessionUrl(sessionId) {
    return this.panelUrl(sessionId).replace("?display=popup", "")
  }

  storageKey() {
    return `paid:chat-popup:${this.accountIdValue}`
  }

  readState() {
    try {
      const rawState = window.localStorage.getItem(this.storageKey())
      if (!rawState) return { open: false, sessionId: null }

      const parsed = JSON.parse(rawState)
      return {
        open: parsed.open === true,
        sessionId: parsed.sessionId || null
      }
    } catch {
      return { open: false, sessionId: null }
    }
  }

  writeState() {
    window.localStorage.setItem(this.storageKey(), JSON.stringify(this.state))
  }

  renderState() {
    const open = this.state.open
    this.panelTarget.classList.toggle("hidden", !open)
    this.buttonTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }

  loadingMarkup() {
    return `
      <div class="flex h-full items-center justify-center rounded-[1.75rem] bg-white p-6 text-sm text-slate-500 shadow-[0_32px_80px_-32px_rgba(15,23,42,0.45)] ring-1 ring-slate-200">
        Loading chat…
      </div>
    `
  }

  errorMarkup() {
    return `
      <div class="flex h-full items-center justify-center rounded-[1.75rem] bg-white p-6 text-center text-sm text-slate-500 shadow-[0_32px_80px_-32px_rgba(15,23,42,0.45)] ring-1 ring-slate-200">
        Unable to load chat right now.
      </div>
    `
  }
}
