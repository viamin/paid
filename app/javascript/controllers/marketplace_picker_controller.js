import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["entry", "group", "queryInput", "typeSelect", "tagSelect", "emptyState", "resultsCount"]

  connect() {
    this.filter()
  }

  filter() {
    const query = this.queryValue()
    const selectedType = this.typeValue()
    const selectedTag = this.tagValue()

    let visibleEntries = 0

    this.entryTargets.forEach((entry) => {
      const matchesQuery = query === "" || entry.dataset.searchText.includes(query)
      const matchesType = selectedType === "" || entry.dataset.entryType === selectedType
      const matchesTag = selectedTag === "" || entry.dataset.tags.split("|").includes(selectedTag)
      const visible = matchesQuery && matchesType && matchesTag

      entry.classList.toggle("hidden", !visible)
      if (visible) visibleEntries += 1
    })

    this.groupTargets.forEach((group) => {
      const hasVisibleEntries = group.querySelectorAll("[data-marketplace-picker-target='entry']:not(.hidden)").length > 0
      group.classList.toggle("hidden", !hasVisibleEntries)
    })

    if (this.hasResultsCountTarget) {
      this.resultsCountTarget.textContent = `${visibleEntries} ${visibleEntries === 1 ? "entry" : "entries"} shown`
    }

    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.toggle("hidden", visibleEntries > 0)
    }
  }

  queryValue() {
    if (!this.hasQueryInputTarget) return ""

    this.queryInputTarget.value.trim().toLowerCase()
  }

  typeValue() {
    if (!this.hasTypeSelectTarget) return ""

    this.typeSelectTarget.value
  }

  tagValue() {
    if (!this.hasTagSelectTarget) return ""

    this.tagSelectTarget.value
  }
}
