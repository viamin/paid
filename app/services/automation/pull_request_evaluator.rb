# frozen_string_literal: true

module Automation
  class PullRequestEvaluator
    include LabelPolicy

    def initialize(record:)
      @record = record
      @project = record.project
    end

    def call(scan: nil, lifecycle: nil)
      explicit_scan_decisions(scan, lifecycle: lifecycle)
    end

    private

    attr_reader :record, :project

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

      StrategyCoordinator.new(project: project).evaluate_pull_request(
        record: record,
        metadata: metadata,
        strategy_types: %i[auto_continue]
      )
    end
  end
end
