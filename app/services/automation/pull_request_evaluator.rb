# frozen_string_literal: true

module Automation
  class PullRequestEvaluator
    include LabelPolicy

    def initialize(record:, explicit_pr_decisions: false)
      @record = record
      @project = record.project
      @explicit_pr_decisions = explicit_pr_decisions
    end

    def call(scan: nil, lifecycle: nil)
      return explicit_scan_decisions(scan, lifecycle: lifecycle) if explicit_pr_decisions

      label_decision_for(project, record)
    end

    private

    attr_reader :record, :project, :explicit_pr_decisions

    # Delegates to {Strategies::AutoContinue}, which applies lifecycle
    # gates (circuit breakers, counter limits, phase transitions) before
    # forwarding to {Strategies::AutoReview} for scan-based decisions.
    #
    # When +lifecycle+ metadata is provided, AutoContinue evaluates
    # gating signals first. When absent it falls back to AutoReview
    # directly, preserving the legacy "scan-only" behavior.
    #
    # Returning early for +nil+ scans (when no lifecycle data is
    # present) preserves the "no scan, no opinion" behavior callers
    # already depend on.
    def explicit_scan_decisions(scan, lifecycle: nil)
      return Result.noop if scan.nil? && lifecycle.nil?

      metadata = {}
      metadata[:scan] = scan if scan
      metadata[:lifecycle] = lifecycle if lifecycle

      context = Context.build(record: record, project: project, metadata: metadata)
      Strategies::AutoContinue.new.evaluate(context)
    end
  end
end
