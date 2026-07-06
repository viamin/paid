# frozen_string_literal: true

module ConfigurationProfiles
  # Catalog of built-in operating-mode postures, expressed as plain Ruby like
  # {OrchestrationStrategies::Defaults}. Each profile pins a target value for
  # every field in {FieldSet}; construction in {Profile} enforces that
  # coverage so the catalog cannot drift as the settings surface evolves.
  module Registry
    module_function

    PROFILES = [
      Profile.new(
        key: :observe_only,
        name: "Observe Only",
        description: "Watch the repository without taking any automated action. " \
                     "Safe default while evaluating Paid.",
        values: {
          auto_pick_enabled: false,
          auto_scan_prs: false,
          automation_on_label_enabled: false,
          auto_merge_mode: "off",
          auto_fix_merge_conflicts: false,
          merge_method: "squash",
          auto_release_granularity: "off",
          auto_enhance_enabled: false,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: false,
          auto_scan_security: false,
          knowledge_evolution_enabled: false,
          allow_bot_authored_pr_auto_merge: false,
          adoption_mode: "observe_only",
          review_paid_agent: false,
          review_copilot: false,
          quality_gate_enabled: false
        }
      ),
      Profile.new(
        key: :manual_on_label,
        name: "Manual On Label",
        description: "Only act when a human adds the automation label. No " \
                     "auto-merge and no automated review; humans stay in the loop.",
        values: {
          auto_pick_enabled: false,
          auto_scan_prs: false,
          automation_on_label_enabled: true,
          auto_merge_mode: "off",
          auto_fix_merge_conflicts: false,
          merge_method: "squash",
          auto_release_granularity: "off",
          auto_enhance_enabled: false,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: false,
          auto_scan_security: false,
          knowledge_evolution_enabled: false,
          allow_bot_authored_pr_auto_merge: false,
          adoption_mode: "advisory",
          review_paid_agent: false,
          review_copilot: false,
          quality_gate_enabled: false
        }
      ),
      Profile.new(
        key: :solo_automated,
        name: "Solo Automated",
        description: "Maximum autonomy for a solo developer: auto-pick, " \
                     "auto-merge everything, paid-agent review, and full auto-release.",
        values: {
          auto_pick_enabled: true,
          auto_scan_prs: true,
          automation_on_label_enabled: true,
          auto_merge_mode: "all",
          auto_fix_merge_conflicts: true,
          merge_method: "squash",
          auto_release_granularity: "all",
          auto_enhance_enabled: true,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: true,
          auto_scan_security: true,
          knowledge_evolution_enabled: true,
          allow_bot_authored_pr_auto_merge: true,
          adoption_mode: "full_execution",
          review_paid_agent: true,
          review_copilot: false,
          quality_gate_enabled: false
        }
      ),
      Profile.new(
        key: :team_reviewed,
        name: "Team Reviewed",
        description: "Auto-pick and auto-enhance stay on for throughput, but " \
                     "human review is required and nothing auto-merges. Quality " \
                     "gates enforce a merge bar.",
        values: {
          auto_pick_enabled: true,
          auto_scan_prs: true,
          automation_on_label_enabled: true,
          auto_merge_mode: "off",
          auto_fix_merge_conflicts: true,
          merge_method: "squash",
          auto_release_granularity: "off",
          auto_enhance_enabled: true,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: true,
          auto_scan_security: true,
          knowledge_evolution_enabled: true,
          allow_bot_authored_pr_auto_merge: false,
          adoption_mode: "review_only",
          review_paid_agent: false,
          review_copilot: false,
          quality_gate_enabled: true
        }
      ),
      Profile.new(
        key: :cost_capped_automated,
        name: "Cost-Capped Automated",
        description: "Keep auto-pick and auto-continue running for throughput, " \
                     "but cap spend by limiting auto-merge to dependabot and " \
                     "disabling auto-release, auto-enhance, and knowledge evolution.",
        values: {
          auto_pick_enabled: true,
          auto_scan_prs: true,
          automation_on_label_enabled: true,
          auto_merge_mode: "dependabot_only",
          auto_fix_merge_conflicts: false,
          merge_method: "squash",
          auto_release_granularity: "off",
          auto_enhance_enabled: false,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: false,
          auto_scan_security: false,
          knowledge_evolution_enabled: false,
          allow_bot_authored_pr_auto_merge: false,
          adoption_mode: "full_execution",
          review_paid_agent: false,
          review_copilot: false,
          quality_gate_enabled: false
        }
      ),
      Profile.new(
        key: :quality_strict,
        name: "Quality Strict",
        description: "Prioritize output quality: paid-agent review and an " \
                     "enabled quality gate gate every change, with auto-enhance " \
                     "filtering issues before work starts. No auto-merge.",
        values: {
          auto_pick_enabled: true,
          auto_scan_prs: true,
          automation_on_label_enabled: true,
          auto_merge_mode: "off",
          auto_fix_merge_conflicts: true,
          merge_method: "squash",
          auto_release_granularity: "off",
          auto_enhance_enabled: true,
          auto_add_labels_enabled: true,
          pr_aggregation_enabled: true,
          auto_scan_security: true,
          knowledge_evolution_enabled: true,
          allow_bot_authored_pr_auto_merge: false,
          adoption_mode: "review_only",
          review_paid_agent: true,
          review_copilot: false,
          quality_gate_enabled: true
        }
      )
    ].freeze

    def all = PROFILES

    def keys = PROFILES.map(&:key).freeze

    def find(key)
      PROFILES.find { |profile| profile.key == key.to_sym }
    end

    def find!(key)
      find(key) || raise(ArgumentError, "Unknown configuration profile: #{key.inspect}")
    end
  end
end
