import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["messageContainer", "typingIndicator"]

  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight
  }
}
