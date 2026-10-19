# frozen_string_literal: true

module FeatureIntents
  # Materializes a feature run's explicitly emitted questions and
  # `[inferred]` decisions into `FeatureIntentDecision` rows
  # (FEATURE-APPROVAL-019). Called when the run's docs-only PR opens —
  # the same attachment point that records the design PR — so the Inbox
  # decision sections render what the run actually raised, never a
  # fabricated default. Recording is idempotent per run: `source_agent_run_id`
  # makes a retried run a no-op, while a chained lid_planning run contributes
  # its own decisions alongside the first run's.
  # @spec FEATURE-APPROVAL-019
  class RecordRunDecisions
    Result = Data.define(:recorded_count) do
      def recorded? = recorded_count.positive?
    end

    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:, agent_run:)
      @feature_intent = feature_intent
      @agent_run = agent_run
    end

    def call
      return Result.new(recorded_count: 0) if feature_intent.nil? || agent_run.nil?
      return Result.new(recorded_count: 0) if recorded_for_run?

      items = RunDecisionEmissions.parse(agent_run.agent_summary_with_stderr_fallback)
      return Result.new(recorded_count: 0) if items.empty?

      ActiveRecord::Base.transaction do
        feature_intent.feature_intent_decisions.create!(items.map { |item| attributes_for(item) })
        transition_on_open_decisions!
      end
      bump_inbox_cache
      Result.new(recorded_count: items.size)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        message: "feature_intent.run_decisions_record_failed",
        feature_intent_id: feature_intent&.id,
        agent_run_id: agent_run&.id,
        error_class: e.class.name,
        error: e.message
      )
      Result.new(recorded_count: 0)
    end

    private

    attr_reader :feature_intent, :agent_run

    def recorded_for_run?
      feature_intent.feature_intent_decisions.exists?(source_agent_run_id: agent_run.id)
    end

    def attributes_for(item)
      {
        kind: item.kind,
        design_claim: item.design_claim,
        prompt: item.prompt,
        status: "open",
        source_agent_run_id: agent_run.id
      }
    end

    # Open decisions block approval, so recording them moves a reviewable
    # feature to `needs_decision`. Approved and terminal statuses are never
    # touched — a late emission cannot reopen a decided feature. The feature
    # returns toward `ready_for_approval` only through the criteria-clarity
    # evaluation that resolution enqueues.
    def transition_on_open_decisions!
      return unless feature_intent.status.in?(%w[design_open ready_for_approval])

      feature_intent.update!(status: "needs_decision")
    end

    def bump_inbox_cache
      Dashboard::CacheVersion.bump(feature_intent.project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    end
  end
end
