# frozen_string_literal: true

module Automation
  class PullRequestEvaluator
    include LabelPolicy

    def initialize(record:, explicit_pr_decisions: false)
      @record = record
      @project = record.project
      @explicit_pr_decisions = explicit_pr_decisions
    end

    def call(scan: nil)
      return explicit_scan_decisions(scan) if explicit_pr_decisions

      label_decision_for(project, record)
    end

    private

    attr_reader :record, :project, :explicit_pr_decisions

    # Delegates to {Strategies::AutoReview}. The strategy owns the
    # per-trigger routing (paid_agent, copilot/codex, manual, ci_action) as
    # well as escalate / dismiss_escalation / owner_approved / ready /
    # follow-up composition. Returning early for +nil+ scans preserves the
    # legacy "no scan, no opinion" behavior callers already depend on.
    def explicit_scan_decisions(scan)
      return Result.noop if scan.nil?

      context = Context.build(record: record, project: project, metadata: { scan: scan })
      Strategies::AutoReview.new.evaluate(context)
    end
  end
end
