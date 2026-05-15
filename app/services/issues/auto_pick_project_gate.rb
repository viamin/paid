# frozen_string_literal: true

module Issues
  class AutoPickProjectGate
    def self.call(project)
      new(project).call
    end

    def initialize(project)
      @project = project
    end

    def call
      return false unless project.auto_pick_enabled?
      return false if project.quality_paused?
      return false if project.scheduler_paused?
      return false if project.account&.scheduler_paused?
      return false unless owner
      return false if deferred_by_pr_attention_limit?

      true
    end

    def context_metadata
      {
        Automation::Strategies::AutoPick::PR_ATTENTION_COUNT_KEY => prs_needing_attention_count,
        Automation::Strategies::AutoPick::PR_ATTENTION_LIMIT_KEY => max_auto_pick_open_prs
      }
    end

    private

    attr_reader :project

    def owner
      @owner ||= project.effective_owner
    end

    def deferred_by_pr_attention_limit?
      limit = max_auto_pick_open_prs
      return false if limit <= 0

      prs_needing_attention_count >= limit
    end

    def prs_needing_attention_count
      base = Issue.where(
        project: project,
        is_pull_request: true,
        github_state: "open",
        paid_state: %w[in_progress failed]
      )

      handed_off = base
        .where(paid_state: "in_progress")
        .where("labels @> ?::jsonb", [ project.automation_label_name, Issues::AutoPick::PAID_READY_LABEL ].to_json)
        .where.not(pr_review_phase: %w[draft restarted])

      escalated = base.where(pr_review_phase: "escalated")

      base.where.not(id: handed_off).where.not(id: escalated).count
    end

    def max_auto_pick_open_prs
      owner&.settings&.max_auto_pick_open_prs || 1
    end
  end
end
