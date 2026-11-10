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
      - Bot-authored PR auto-merge: #{bot_authored_merge_permission}
      - Enabled review methods: #{enabled_review_methods.presence || "none"}
      - Manual review: #{manual_review_enabled? ? "enabled" : "disabled"}
      - Human approval: #{human_approval_posture}
      - TDD gate: #{tdd_mode}

      Normal automation is authorized to handle the work described by this
      posture. Normal CI, enabled bot review, screenshots, and merge checks
      remain in force. `auto_merge_mode: all` delegates ordinary merge
      decisions; it does not override an explicit human-only decision,
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
      bot_authored_pr_auto_merge: bot_authored_pr_auto_merge?,
      review_methods: enabled_review_methods_list,
      manual_review_enabled: manual_review_enabled?,
      human_approval: human_approval_posture,
      tdd_mode: tdd_mode
    }
  end

  def auto_merge_mode
    project.respond_to?(:auto_merge_mode) ? project.auto_merge_mode.to_s : "off"
  end

  def bot_authored_pr_auto_merge?
    project.respond_to?(:allow_bot_authored_pr_auto_merge?) && project.allow_bot_authored_pr_auto_merge?
  end

  def bot_authored_merge_permission
    bot_authored_pr_auto_merge? ? "permitted" : "not permitted"
  end

  def review_settings
    return {} unless project.respond_to?(:effective_review_settings)

    project.effective_review_settings.to_h.deep_stringify_keys
  end

  def enabled_review_methods_list
    return [] unless review_settings["enabled"] == true

    review_settings.fetch("methods", {}).filter_map do |name, settings|
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
    return agent_run.tdd_phase if agent_run&.respond_to?(:tdd_governed?) && agent_run.tdd_governed?

    project.respond_to?(:tdd_mode) ? project.tdd_mode.to_s : "off"
  end
end
