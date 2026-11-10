# frozen_string_literal: true

# Renders the project policy that will govern a PR created by this run. This
# is resolved when the prompt is assembled so queued work never acts on stale
# merge or review settings. The metadata intentionally contains settings only,
# never review credentials or other secrets.
# @spec PROMPT-ASSEMBLY-025, AUTO-MERGE-009
class PromptAssembly::Sections::EffectiveMergeReviewPosture
  include PromptAssembly::Sections::Base

  private

  def build_section
    <<~POSTURE
      # Effective Merge and Review Posture

      This is the current project policy resolved when this run starts.
      - Auto-merge mode: #{auto_merge_mode}
      - Auto-merge automation: #{auto_merge_phase_authorization}
      - Bot-authored PR auto-merge: #{bot_authored_merge_permission}
      - Enabled review methods: #{enabled_review_methods.presence || "none"}
      - Manual review: #{manual_review_enabled? ? "enabled" : "disabled"}
      - Human approval: #{human_approval_posture}
      - TDD gate: #{tdd_mode}

      Normal CI, enabled bot review, screenshots, and merge checks remain in
      force. Automatic merge delegates only the ordinary merge decision; it
      does not override an explicit human-only decision,
      repository protection, or the `paid-hold-review` label. Apply that label
      only when this PR has a concrete human-only decision to retain.
    POSTURE
  end

  def required = true

  def inclusion_reason
    "current project merge, review, approval, and TDD settings"
  end

  def section_metadata
    {
      auto_merge_mode: auto_merge_mode,
      auto_merge_phase_authorized: auto_merge_phase_authorized?,
      bot_authored_pr_auto_merge: bot_authored_pr_auto_merge?,
      review_methods: enabled_review_methods_list,
      manual_review_enabled: manual_review_enabled?,
      human_approval: human_approval_posture,
      tdd_mode: tdd_mode
    }
  end

  # Stored settings can outlive the runtime gates (an upstream-target project
  # may still hold legacy enabled values), so each posture value resolves
  # through the same effective Project predicates the merge/review runtime
  # uses — auto_merge_enabled?, auto_merge_bot_authored?, review_enabled?, and
  # merge-phase authorization — never the raw columns.
  def auto_merge_mode
    return "off" unless auto_merge_enabled? && auto_merge_phase_authorized?

    project.respond_to?(:auto_merge_mode) ? project.auto_merge_mode.to_s : "off"
  end

  def auto_merge_enabled?
    return true unless project.respond_to?(:auto_merge_enabled?)

    project.auto_merge_enabled?
  end

  def bot_authored_pr_auto_merge?
    auto_merge_mode == "all" && project.respond_to?(:auto_merge_bot_authored?) && project.auto_merge_bot_authored?
  end

  def auto_merge_phase_authorized?
    return @auto_merge_phase_authorized unless @auto_merge_phase_authorized.nil?

    @auto_merge_phase_authorized = Automation::FeatureActivation.phase_authorized?(project:, capability: "auto_merge")
  end

  def auto_merge_phase_authorization
    auto_merge_phase_authorized? ? "enabled" : "disabled by merge phase"
  end

  def bot_authored_merge_permission
    bot_authored_pr_auto_merge? ? "permitted" : "not permitted"
  end

  def review_settings
    return {} unless project.respond_to?(:effective_review_settings)

    project.effective_review_settings.to_h.deep_stringify_keys
  end

  def review_automation_enabled?
    return review_settings["enabled"] == true unless project.respond_to?(:review_enabled?)

    project.review_enabled?
  end

  def enabled_review_methods_list
    return [] unless review_automation_enabled?

    (review_settings["methods"] || {}).filter_map do |name, settings|
      name if settings.is_a?(Hash) && settings["enabled"] == true
    end
  end

  def enabled_review_methods
    enabled_review_methods_list.join(", ")
  end

  def manual_review_enabled?
    enabled_review_methods_list.include?("manual")
  end

  def human_approval_posture
    return "not applicable while project auto-merge is off" if auto_merge_mode == "off"
    return "not applicable to the Dependabot-only merge path" if auto_merge_mode == "dependabot_only"

    "required for ordinary human-authored PRs before automatic merge"
  end

  def tdd_mode
    if agent_run&.respond_to?(:tdd_governed?) && agent_run.tdd_governed?
      return Automation::FeatureActivation.issue_tdd_mode(project:, issue:)
    end

    project.respond_to?(:tdd_mode) ? project.tdd_mode.to_s : "off"
  end
end
