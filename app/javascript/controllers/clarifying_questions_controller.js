import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["step", "answer", "progressBar", "progressAnswered", "progressPercent", "form", "submitButton"]
  static values = { total: Number }

  connect() {
    this.currentIndex = 0
    this.updateProgress()
  }

  next() {
    if (!this.validateCurrentStep()) return
    if (this.currentIndex < this.stepTargets.length - 1) {
      this.currentIndex++
      this.showStep(this.currentIndex)
    }
  }

  previous() {
    if (this.currentIndex > 0) {
      this.currentIndex--
      this.showStep(this.currentIndex)
    }
  }

  showStep(index) {
    this.stepTargets.forEach((step, i) => {
      step.style.display = i === index ? "" : "none"
    })
    this.updateProgress()
  }

  validateCurrentStep() {
    const currentStep = this.stepTargets[this.currentIndex]
    if (!currentStep) return true

    const textarea = currentStep.querySelector("textarea")
    if (textarea && textarea.required && !textarea.value.trim()) {
      textarea.focus()
      textarea.classList.add("border-red-500")
      return false
    }
    if (textarea) {
      textarea.classList.remove("border-red-500")
    }
    return true
  }

  updateProgress() {
    const total = this.totalValue
    const answered = this.answerTargets.filter(a => a.value.trim().length > 0).length
    const percent = total > 0 ? Math.round((answered / total) * 100) : 0

    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${percent}%`
    }
    if (this.hasProgressAnsweredTarget) {
      this.progressAnsweredTarget.textContent = answered
    }
    if (this.hasProgressPercentTarget) {
      this.progressPercentTarget.textContent = percent
    }
  }
}
