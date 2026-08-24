import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "runner"]

  connect() {
    this.defaultLabel = this.hasButtonTarget ? this.buttonTarget.textContent.trim() : "Test All"
  }

  // @spec RUNNERS-INDEX-010
  async testAll(event) {
    event.preventDefault()
    if (!this.hasButtonTarget || this.runnerTargets.length === 0 || this.buttonTarget.disabled) return

    const total = this.runnerTargets.length
    let completed = 0

    this.updateButton(`Testing... ${completed}/${total}`, true)

    const tests = this.runnerTargets.map((runnerElement) =>
      Promise.resolve(this.testRunner(runnerElement)).finally(() => {
        completed += 1
        if (!this.element.isConnected) return

        this.updateButton(`Testing... ${completed}/${total}`, true)
      })
    )

    await Promise.allSettled(tests)
    if (!this.element.isConnected) return

    this.updateButton(`Tested ${completed}/${total}`, false)
  }

  testRunner(runnerElement) {
    const controller = this.application.getControllerForElementAndIdentifier(runnerElement, "test-agent")
    return controller ? controller.test() : Promise.resolve()
  }

  updateButton(label, disabled) {
    this.buttonTarget.disabled = disabled
    this.buttonTarget.textContent = label
  }
}
