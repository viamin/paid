import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sectionTab", "sectionPanel"]

  connect() {
    this.showFirstSection()
  }

  showFirstSection() {
    if (this.hasSectionPanelTarget) {
      const firstSection = this.sectionPanelTargets[0]
      if (firstSection) {
        this.activateSection(firstSection.dataset.section)
      }
    }
  }

  switchSection(event) {
    const section = event.currentTarget.dataset.section
    this.activateSection(section)
  }

  activateSection(sectionKey) {
    this.sectionPanelTargets.forEach((panel) => {
      panel.style.display = panel.dataset.section === sectionKey ? "" : "none"
    })

    this.sectionTabTargets.forEach((tab) => {
      if (tab.dataset.section === sectionKey) {
        tab.classList.add("bg-indigo-100", "text-indigo-700")
        tab.classList.remove("text-gray-500")
      } else {
        tab.classList.remove("bg-indigo-100", "text-indigo-700")
        tab.classList.add("text-gray-500")
      }
    })
  }
}
