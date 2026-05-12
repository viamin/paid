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

  submit(event) {
    if (this.allAnswersPresent()) return

    event.preventDefault()
    this.focusFirstBlankAnswer()
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
    const answered = this.answerTargets.filter((answer) => {
      const present = answer.value.trim().length > 0
      if (present) answer.classList.remove("border-red-500")
      return present
    }).length
    const percent = total > 0 ? Math.round((answered / total) * 100) : 0
    const allAnswered = total > 0 && answered === total

    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${percent}%`
    }
    if (this.hasProgressAnsweredTarget) {
      this.progressAnsweredTarget.textContent = answered
    }
    if (this.hasProgressPercentTarget) {
      this.progressPercentTarget.textContent = percent
    }
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = !allAnswered
      this.submitButtonTarget.setAttribute("aria-disabled", (!allAnswered).toString())
    }
  }

  allAnswersPresent() {
    return this.answerTargets.every(answer => answer.value.trim().length > 0)
  }

  focusFirstBlankAnswer() {
    const blankAnswer = this.answerTargets.find(answer => answer.value.trim().length === 0)
    if (!blankAnswer) return

    const stepIndex = Number(blankAnswer.dataset.stepIndex)
    this.currentIndex = stepIndex
    this.showStep(stepIndex)
    blankAnswer.classList.add("border-red-500")
    blankAnswer.focus()
  }
}
