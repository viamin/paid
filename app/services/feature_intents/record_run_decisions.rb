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
        decisions = feature_intent.feature_intent_decisions.create!(items.map { |item| attributes_for(item) })
        plan_checkpoint!(decisions)
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

    # @spec PROJECT-DELEGATION-002 — the same choke point groups the run's
    # recorded decisions into one revision-bound checkpoint, so a single
    # human settlement covers the whole group and RespondToDecision can
    # settle the checkpoint once every question is answered. A run whose
    # design or acceptance revision is not resolvable yet records no
    # checkpoint: an unbound checkpoint could never be settled.
    def plan_checkpoint!(decisions)
      return if decisions.empty?
      return if design_revision.blank? || acceptance_revision.blank?

      ProjectDelegation::IntentCheckpoint::Plan.call(
        feature_intent:, questions: decisions,
        recommendation: "Settle the material questions raised by run ##{agent_run.id} before approving the design.",
        alternatives: [],
        consequences: [ "Feature approval stays blocked until every recorded question is settled." ],
        affected_scope: { "design_claims" => decisions.map(&:design_claim) },
        evidence: [ { "source" => "agent_run", "reference" => agent_run.id.to_s } ],
        design_revision:, acceptance_revision:
      )
    end

    # The design revision the run's decisions were raised against: the
    # reviewed head of the most recently attached design PR. Recording runs
    # right after FeatureIntents::AttachFromAgentRun.attach_design_pr, so
    # this is the design evidence the run examined.
    def design_revision
      design_pr = feature_intent.feature_intent_design_prs.order(:id).last
      return if design_pr.nil?

      design_pr.reviewed_head_sha.presence || design_pr.head_sha
    end

    # The canonical acceptance revision token shared with delegated-work
    # admission, computed for the run's brief issue.
    def acceptance_revision
      return if agent_run.issue.nil?

      Automation::DelegatedActionAdmission.revision_tokens(issue: agent_run.issue)["acceptance_revision"]
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
