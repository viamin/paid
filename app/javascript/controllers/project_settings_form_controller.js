import { Controller } from "@hotwired/stimulus"

const SUBMITTABLE_INPUT_TYPES = new Set([
  "date",
  "datetime-local",
  "email",
  "month",
  "number",
  "password",
  "search",
  "tel",
  "text",
  "time",
  "url",
  "week"
])

// Mirrors Project::PR_TARGET_UPSTREAM_DISABLED_ATTRIBUTES — the set of
// project settings that cannot operate against a repository Paid does not
// own or trust. Keep in sync with the model when fields are added or
// removed.
//
// auto_fix_merge_conflicts is deliberately NOT in this set: conflict-fix
// runs only ever push to the fork-owned head branch (Paid's working copy),
// so they are safe in upstream mode (#4082).
// @spec PR-TARGET-002, PR-TARGET-003, PR-TARGET-014
const UPSTREAM_DISABLED_ATTRIBUTES = new Set([
  "review_settings",
  "auto_merge_mode",
  "allow_bot_authored_pr_auto_merge",
  "auto_release_granularity",
  "owner_reviewer_login",
  "pr_approval_escalation_hours",
  "max_draft_review_rounds",
  "max_pr_auto_continue_tokens",
  "auto_add_labels_enabled",
  "generated_label_name",
  "automation_label_name",
  "automation_on_label_enabled",
  "screenshot_settings"
])

export default class extends Controller {
  static targets = [
    "saveButton",
    "githubAuthSource",
    "appPanel",
    "patPanel",
    "prTarget",
    "prTargetUpstreamPanel",
    "prTargetUpstreamNote",
    "prTargetGatedField"
  ]

  connect() {
    this.toggleGithubAuthSections()
    this.applyPrTargetGating()
  }

  githubAuthSourceChanged() {
    this.toggleGithubAuthSections()
  }

  prTargetChanged() {
    this.applyPrTargetGating()
  }

  submitOnEnter(event) {
    if (!this.shouldSubmitOnEnter(event)) return

    event.preventDefault()
    this.element.requestSubmit(this.saveButtonTarget)
  }

  shouldSubmitOnEnter(event) {
    return event.key === "Enter" &&
      !event.defaultPrevented &&
      !event.isComposing &&
      !event.shiftKey &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      this.hasSaveButtonTarget &&
      this.submittableInput(event.target)
  }

  submittableInput(target) {
    if (!target || target.tagName !== "INPUT") return false

    return SUBMITTABLE_INPUT_TYPES.has(target.type)
  }

  toggleGithubAuthSections() {
    if (!this.hasAppPanelTarget || !this.hasPatPanelTarget) return

    const appSelected = this.selectedGithubAuthSource() === "app"
    this.appPanelTarget.classList.toggle("hidden", !appSelected)
    this.patPanelTarget.classList.toggle("hidden", appSelected)
  }

  selectedGithubAuthSource() {
    const selected = this.githubAuthSourceTargets.find((input) => input.checked)
    return selected?.value
  }

  // True when the upstream radio is selected. Falls back to the persisted
  // radio state on initial connect so the initial render matches server-side.
  upstreamSelected() {
    if (!this.hasPrTargetTarget) return false
    const selected = this.prTargetTargets.find((input) => input.checked)
    return selected?.value === "upstream"
  }

  applyPrTargetGating() {
    const upstream = this.upstreamSelected()

    if (this.hasPrTargetUpstreamPanelTarget) {
      this.prTargetUpstreamPanelTarget.classList.toggle("hidden", !upstream)
    }
    if (this.hasPrTargetUpstreamNoteTarget) {
      this.prTargetUpstreamNoteTarget.classList.toggle("hidden", !upstream)
    }

    this.prTargetGatedFieldTargets.forEach((target) => {
      const attribute = target.dataset.attribute
      const shouldGate = upstream && UPSTREAM_DISABLED_ATTRIBUTES.has(attribute)
      this.setFieldDisabledState(target, shouldGate)
    })
  }

  setFieldDisabledState(container, disabled) {
    const inputs = container.querySelectorAll("input, select, textarea, button")
    inputs.forEach((input) => {
      if (input.type === "hidden") return
      input.disabled = disabled
    })
    container.classList.toggle("opacity-50", disabled)
    container.classList.toggle("pointer-events-none", disabled)
  }
}
