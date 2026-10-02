# frozen_string_literal: true

# Central server-side authority for upstream-mode feature restrictions
# (#4078, corrected in #4082). When a project's pull requests target a
# configured upstream repository ("upstream mode"), Paid has no trusted
# access to that repository, so no automation may act on it or on the PRs
# opened in it beyond creating the PR and editing our own PR's title,
# body, and draft state.
#
# This concern is the ONE place that decides what upstream mode disables:
#
# - {#upstream_pr_target?} — the mode predicate (pr_target "upstream" with
#   the upstream repository configured).
# - {DISABLED_FEATURES} — the canonical disable list. Every gated feature
#   consults {#upstream_automation_allowed?} / {#upstream_feature_enabled?}
#   instead of reading +pr_target+ itself.
# - {#log_upstream_mode_skipped} — the shared observability hook; emits one
#   info log (+upstream_mode_skipped+ with the feature name) per feature per
#   project instance so skips are explainable, never silent.
# - +upstream_mode_automation_settings_valid+ — save-time hard gating: a
#   project in upstream mode cannot store an enabled value for a gated
#   feature. The UI grays the settings out (#4076); the model is the
#   authority.
#
# Issue-side automation on the project's own fork (issue polling, auto-pick,
# enhance, issue labeling on fork issues) is deliberately NOT gated: those
# issues live in the project's own fork, which Paid controls. The
# +upstream_issue_labeling+ and +upstream_issue_comments+ keys gate the
# upstream-side paths (#4079 / #4082).
#
# @spec UPSTREAM-GATE-001 UPSTREAM-GATE-002 UPSTREAM-GATE-004
# @spec UPSTREAM-GATE-006
module Project::UpstreamAutomation
  extend ActiveSupport::Concern

  # The canonical upstream-mode disable set. Keys are the feature symbols
  # accepted by {#upstream_automation_allowed?}; each entry documents the
  # concrete settings and code paths it silences:
  #
  # - +pr_reviews+ — every review_settings method (Copilot, Paid PR Code
  #   Review Agent, Codex, CI Review Action, manual), auto-review, and
  #   review re-requests on PRs.
  # - +auto_merge+ — auto_merge_mode, allow_bot_authored_pr_auto_merge, the
  #   Dependabot auto-merge path, and owner-approval merges.
  # - +auto_release+ — auto_release_granularity and every release-please
  #   interaction.
  # - +auto_scan_prs+ — ScanPaidPrsActivity follow-up scanning (CI signals,
  #   bot/human review signals, label-triggered follow-ups).
  # - +pr_labeling+ — labels Paid adds to PRs it opens (auto_add_labels on
  #   PRs, priority-label inheritance). Issue labeling on the project's own
  #   fork stays allowed.
  # - +owner_review_requests+ — owner_reviewer_login review requests and
  #   pr_approval_escalation_hours escalation.
  # - +draft_review_rounds+ — max_draft_review_rounds and
  #   max_pr_auto_continue_tokens budgets (inert upstream: no draft-review
  #   or follow-up runs are ever produced because scanning is skipped).
  # - +screenshots+ — screenshot capture and PR comments on agent-created
  #   PRs.
  # - +upstream_issue_labeling+ — labeling writes against issues and PRs
  #   hosted in the upstream repository. The "Sync Labels to GitHub" action
  #   (Projects::EnsureStandardLabels) is gated under this feature because
  #   it touches the upstream repository's label set, and the
  #   label-application paths in CreatePullRequestActivity /
  #   CreateAggregatedPullRequestActivity are gated because they would write
  #   to upstream PRs (#4079 / #4082).
  # - +upstream_issue_comments+ — comment writes against issues and PRs
  #   hosted in the upstream repository (#4079 / #4082).
  #
  # Note: +auto_fix_merge_conflicts+ is deliberately NOT in this set.
  # Conflict-fix runs only ever push to the fork-owned head branch — the
  # agent run's working copy on the project's own repository — so they
  # never write the upstream base. They remain fully active in upstream
  # mode (#4082). See {UPSTREAM-GATE-006}.
  #
  # @spec UPSTREAM-GATE-001
  DISABLED_FEATURES = %i[
    pr_reviews
    auto_merge
    auto_release
    auto_scan_prs
    pr_labeling
    owner_review_requests
    draft_review_rounds
    screenshots
    upstream_issue_labeling
    upstream_issue_comments
  ].freeze

  # Save-time gate: maps each gated setting to a predicate over its value
  # that returns true when the value would ENABLE the gated feature. Shared
  # by the model validation and Tools::UpdateProjectSettings so the
  # "enabled value" definition lives in exactly one place.
  #
  # +auto_fix_merge_conflicts+ is NOT in this map: the setting stays
  # editable in upstream mode and conflict-fix runs remain active (#4082).
  # @spec UPSTREAM-GATE-004
  GATED_SETTING_CHECKS = {
    "auto_merge_mode" => ->(value) { value.present? && value != "off" },
    "allow_bot_authored_pr_auto_merge" => ->(value) { cast_bool(value) },
    "auto_release_granularity" => ->(value) { value.present? && value != "off" },
    "review_settings" => ->(value) { review_settings_enable_automation?(value) },
    "auto_add_labels_enabled" => ->(value) { cast_bool(value) },
    "inherit_priority_labels" => ->(value) { cast_bool(value) },
    "owner_reviewer_login" => ->(value) { value.present? },
    "screenshot_settings" => ->(value) { screenshot_settings_enable_automation?(value) }
  }.freeze

  GATED_SETTING_ERROR = "is not available while PRs target the upstream repository"

  included do
    validate :upstream_target_requires_upstream_repo
    validate :upstream_mode_automation_settings_valid
    # When pr_target transitions into upstream mode, atomically clear any
    # currently-enabled gated setting so the save can proceed. The UI grays
    # those inputs out (#4076) so the request only submits the new
    # pr_target / upstream_full_name and the persisted defaults (e.g.
    # auto_add_labels_enabled=true, inherit_priority_labels=true) would
    # otherwise fail the {#upstream_mode_automation_settings_valid} check
    # (#4082). Defense-in-depth: the chat path still checks submitted attrs
    # via {#upstream_gated_setting_violations} (UPSTREAM-GATE-005), so an
    # explicit attempt to enable a gated setting on an existing upstream
    # project is rejected by the validation, not silently overridden here.
    # @spec UPSTREAM-GATE-004
    before_validation :clear_gated_settings_on_upstream_transition
  end

  # True when this project opens PRs against a configured upstream
  # repository. This is the ONLY method downstream code should consult;
  # nothing outside this concern reads +pr_target+ directly.
  # @spec UPSTREAM-GATE-002
  def upstream_pr_target?
    pr_target == "upstream" && upstream_full_name.present?
  end

  # The named capability check every gated feature must consult. Returns
  # false only when upstream mode is active and +feature+ is in the
  # {DISABLED_FEATURES} set.
  # @spec UPSTREAM-GATE-001
  def upstream_automation_allowed?(feature)
    !upstream_mode_skips?(feature)
  end

  # True when upstream mode silences +feature+. Pure (no logging) — use
  # {#upstream_feature_enabled?} at feature entry points that need the
  # +upstream_mode_skipped+ observability log.
  def upstream_mode_skips?(feature)
    upstream_pr_target? && DISABLED_FEATURES.include?(feature.to_sym)
  end

  # Capability check with the observability hook: returns false and logs
  # +upstream_mode_skipped+ (once per feature per instance) when upstream
  # mode disables +feature+.
  # @spec UPSTREAM-GATE-003
  def upstream_feature_enabled?(feature)
    return true if upstream_automation_allowed?(feature)

    log_upstream_mode_skipped(feature)
    false
  end

  # Emits the single info log for a gated feature skipped by upstream mode.
  # Memoized per feature per project instance so a run that consults a
  # predicate repeatedly still logs exactly once.
  # @spec UPSTREAM-GATE-003
  def log_upstream_mode_skipped(feature, **metadata)
    return unless upstream_pr_target?

    feature_key = feature.to_sym
    @upstream_skip_logged ||= {}
    return if @upstream_skip_logged[feature_key]

    @upstream_skip_logged[feature_key] = true
    Rails.logger.info(
      { message: "upstream_mode_skipped", project_id: id, feature: feature_key.to_s }.merge(metadata)
    )
  end

  # Returns the gated-setting keys in +attrs+ whose values would enable a
  # gated feature while upstream mode is active. Used by the chat settings
  # tool so the chat path cannot bypass the form's disabled inputs.
  # @spec UPSTREAM-GATE-005
  def upstream_gated_setting_violations(attrs)
    return [] unless upstream_pr_target?

    attrs.stringify_keys
      .slice(*GATED_SETTING_CHECKS.keys)
      .select { |attribute, value| GATED_SETTING_CHECKS.fetch(attribute).call(value) }
      .keys
  end

  private

  # Upstream PR targeting is meaningless without the upstream repository to
  # target; catching it at save time keeps "pr_target upstream" and "upstream
  # mode active" from drifting apart.
  def upstream_target_requires_upstream_repo
    return if pr_target != "upstream"
    return if upstream_full_name.present?

    errors.add(:upstream_full_name, "is required when PR target is upstream")
  end

  # Save-time hard gating (#4078 requirement 3): while the project targets
  # PRs upstream, rejects any save that would leave a gated feature enabled,
  # instead of storing the value and silently ignoring it at runtime.
  # Switching pr_target back to "own_repo" clears the gate and restores
  # normal behavior.
  # @spec UPSTREAM-GATE-004
  def upstream_mode_automation_settings_valid
    return if pr_target != "upstream"

    GATED_SETTING_CHECKS.each do |attribute, check|
      next unless will_save_change_to_attribute?(attribute.to_sym)
      next unless check.call(public_send(attribute))

      errors.add(attribute.to_sym, GATED_SETTING_ERROR)
    end
  end

  # When pr_target transitions from "own_repo" (or unset on a new record)
  # into "upstream", reset every gated setting to its disabled default so
  # the persisted column defaults (notably auto_add_labels_enabled=true and
  # inherit_priority_labels=true) do not block the transition. The
  # {#upstream_mode_automation_settings_valid} check then sees cleared
  # values and the save proceeds. This callback only clears attributes
  # that are currently enabled, so a project that was already on upstream
  # mode (and whose gated settings were therefore already disabled) is
  # untouched on subsequent updates.
  # @spec UPSTREAM-GATE-004
  def clear_gated_settings_on_upstream_transition
    return unless pr_target == "upstream"
    return if pr_target_was == "upstream"

    GATED_SETTING_CHECKS.each do |attribute, check|
      value = public_send(attribute)
      next unless check.call(value)

      public_send("#{attribute}=", upstream_gated_disabled_default(attribute))
    end
  end

  # The "disabled" default for each gated setting: anything that makes
  # the corresponding {GATED_SETTING_CHECKS} predicate return false.
  # Centralized here so the transition-clear behavior and any future
  # programmatic reset (e.g. a "Switch back to own_repo" admin action)
  # cannot drift apart.
  def upstream_gated_disabled_default(attribute)
    case attribute.to_s
    when "auto_merge_mode", "auto_release_granularity"
      "off"
    when "owner_reviewer_login"
      nil
    when "review_settings", "screenshot_settings"
      {}
    else
      false
    end
  end

  class << self
    # True when a review_settings value turns on any review automation —
    # the top-level toggle or any individual method sub-flag.
    def review_settings_enable_automation?(value)
      return false unless value.is_a?(Hash)

      normalized = value.deep_stringify_keys
      return true if normalized["enabled"] == true

      methods = normalized["methods"]
      methods.is_a?(Hash) && methods.any? { |_name, config| config.is_a?(Hash) && config["enabled"] == true }
    end

    # True when a screenshot_settings value turns on screenshot capture.
    def screenshot_settings_enable_automation?(value)
      return false unless value.is_a?(Hash)

      cast_bool(value.deep_stringify_keys["enabled"])
    end

    def cast_bool(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
