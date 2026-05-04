# frozen_string_literal: true

require "rails_helper"

# Parity checklist for the automation modularization migration.
#
# These tests verify that the modular automation architecture preserves
# the expected behavior of the prior monolithic implementation across
# the full decision space. Each test documents a specific behavior that
# must remain stable during the migration.
#
# When extending the automation system, add a test here for any
# behavior that spans multiple modules or crosses a strategy boundary.
RSpec.describe Automation::Strategy do
  context "with parity checklist" do
  let(:project) { create(:project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, paid_state: "new")
  end

  def evaluate_auto_continue(lifecycle: nil, scan: nil)
    metadata = {}
    metadata[:lifecycle] = lifecycle if lifecycle
    metadata[:scan] = scan if scan

    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: metadata
    )
    Automation::Strategies::AutoContinue.new.evaluate(context)
  end

  def evaluate_auto_review(scan: {})
    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: { scan: scan }
    )
    Automation::Strategies::AutoReview.new.evaluate(context)
  end

  def evaluate_auto_pick
    context = Automation::Context.build(
      record: nil,
      project: project,
      metadata: {}
    )
    Automation::Strategies::AutoPick.new.evaluate(context)
  end

  def evaluate_auto_merge(signals: nil)
    context = Automation::Context.build(
      record: nil,
      project: project,
      metadata: { Automation::Strategies::AutoMerge::SIGNALS_KEY => signals }
    )
    Automation::Strategies::AutoMerge.new.evaluate(context)
  end

  def decision_types(result)
    result.to_h[:decisions].map { |d| d[:type] }
  end

  # -- Strategy contract parity --

  describe "strategy module contract" do
    it "all strategies include Automation::Strategy" do
      [
        Automation::Strategies::AutoPick,
        Automation::Strategies::AutoContinue,
        Automation::Strategies::AutoReview,
        Automation::Strategies::AutoMerge
      ].each do |klass|
        expect(klass.ancestors).to include(described_class),
          "#{klass} must include Automation::Strategy"
      end
    end

    it "all strategies return Automation::Result from #evaluate" do
      expect([
        evaluate_auto_pick,
        evaluate_auto_continue,
        evaluate_auto_review,
        evaluate_auto_merge
      ]).to all(be_a(Automation::Result))
    end
  end

  # -- Decision type parity --

  describe "decision factory completeness" do
    it "supports all known decision types" do
      known_types = %w[
        noop
        queue_create_pr_run
        queue_review_run
        start_planning
        request_review
        dispatch_claude_review
        mark_ready
        escalate
        dismiss_escalation
        merge
        record_pr_followup
        record_review_goal_retry
        queue_analyze_issue_run
      ]

      known_types.each do |type|
        factory_method = type.to_sym
        expect(Automation::Decision).to respond_to(factory_method),
          "Automation::Decision must have a .#{factory_method} factory method"
      end
    end
  end

  # -- Review method registry parity --

  describe "review method registry" do
    it "maps all canonical review method names to plugin classes" do
      Automation::Configuration::ReviewMethod::NAMES.each do |name|
        expect { Automation::ReviewMethods::Registry.resolve(name) }.not_to raise_error,
          "Registry must resolve #{name.inspect}"
      end
    end

    it "each plugin reports a valid kind symbol" do
      valid_kinds = %i[bot agent comment_bot human ci]

      Automation::Configuration::ReviewMethod::NAMES.each do |name|
        plugin_class = Automation::ReviewMethods::Registry.resolve(name)
        config = Automation::Configuration::AutoReview.new(
          review_settings: Automation::Configuration::ReviewSettings.from_hash(
            "enabled" => true,
            "methods" => Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) { |n, h|
              h[n.to_s] = { "enabled" => true }
            }
          )
        )
        signals = Automation::Strategies::AutoReview::Signals.from_scan(pr_number: 1)
        plugin = plugin_class.new(method: config.method_for(name), config: config, signals: signals)

        expect(valid_kinds).to include(plugin.kind),
          "Plugin for #{name.inspect} reported unexpected kind: #{plugin.kind.inspect}"
      end
    end
  end

  # -- Provider interface parity --

  describe "provider capability modules" do
    it "all three capability modules define a ProviderError" do
      [
        Automation::Providers::RepositoryProvider,
        Automation::Providers::WorkItemProvider,
        Automation::Providers::ReviewProvider
      ].each do |mod|
        expect(mod.const_defined?(:ProviderError)).to be(true),
          "#{mod} must define ProviderError"
        expect(mod::ProviderError.ancestors).to include(StandardError)
      end
    end
  end

  # -- Data class parity --

  describe "data class state enumerations" do
    it "PullRequest declares expected STATES" do
      expect(Automation::Providers::Data::PullRequest::STATES).to contain_exactly(:open, :closed)
    end

    it "Issue declares expected STATES" do
      expect(Automation::Providers::Data::Issue::STATES).to contain_exactly(:open, :closed)
    end

    it "Review declares expected STATES" do
      expect(Automation::Providers::Data::Review::STATES).to contain_exactly(
        :approved, :changes_requested, :commented, :dismissed, :pending
      )
    end

    it "CheckRun declares expected STATUSES" do
      expect(Automation::Providers::Data::CheckRun::STATUSES).to contain_exactly(
        :queued, :in_progress, :completed
      )
    end

    it "Outcome declares expected STATES" do
      expect(Automation::Strategies::AutoReview::Outcome::STATES).to contain_exactly(
        :pending, :satisfied, :retryable_failure, :exhausted_retries, :not_applicable
      )
    end
  end

  # -- Auto-review trigger routing parity --

  describe "trigger priority in AutoReview" do
    it "escalate_to_owner takes priority over all other triggers" do
      result = evaluate_auto_review(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "escalated",
        owner_reviewer_login: "bob",
        triggers: [
          { type: "escalate_to_owner", details: "budget exhausted" },
          { type: "owner_approved" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      expect(decision_types(result)).to eq([ "escalate" ])
    end

    it "owner_approved takes priority over review triggers" do
      result = evaluate_auto_review(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [
          { type: "owner_approved" },
          { type: "paid_agent_review_pending" }
        ]
      })

      expect(decision_types(result)).to eq([ "merge" ])
    end

    it "review_goal_retry takes priority over paid_agent_review_pending" do
      result = evaluate_auto_review(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_review_goal_retry_count: 1,
        triggers: [
          { type: "review_goal_retry" },
          { type: "paid_agent_review_pending" }
        ]
      })

      types = decision_types(result)
      expect(types.first).to eq("record_review_goal_retry")
    end
  end

  # -- AutoContinue delegation parity --

  describe "AutoContinue delegates to AutoReview" do
    let(:owner_approved_scan) do
      { issue_id: pull_request.id, pr_number: 42, phase: "ready",
        triggers: [ { type: "owner_approved" } ] }
    end

    let(:passthrough_lifecycle) do
      { issue_id: pull_request.id, pr_number: 42, phase: "ready",
        active_run_exists: false, operational_failure_breaker: false,
        draft_review_limit_reached: false, consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false, followup_limit_reached: false,
        escalation_dismissed: false, owner_reviewer_login: "alice",
        escalation_reason: nil, draft: false }
    end

    it "produces the same merge decision as direct AutoReview evaluation" do
      direct = evaluate_auto_review(scan: owner_approved_scan)
      via_continue = evaluate_auto_continue(
        lifecycle: passthrough_lifecycle, scan: owner_approved_scan
      )

      expect(decision_types(via_continue)).to eq(decision_types(direct))
    end
  end

  # -- AutoMerge parity --

  describe "AutoMerge precondition coverage" do
    before do
      allow(project).to receive_messages(
        auto_merge_enabled?: true,
        merge_method: "squash",
        auto_fix_merge_conflicts: false
      )
    end

    let(:all_human_preconditions) do
      { issue_id: 42, pr_number: 10, owner_approved: true, checks_green: true,
        mergeable: true, review_feedback_clear: true, blocking_reviews_complete: true,
        reviews_fresh: true }
    end

    it "merges a human PR when all six preconditions are met" do
      signals = Automation::Strategies::AutoMerge::Signals.build(**all_human_preconditions)
      result = evaluate_auto_merge(signals: signals)

      expect(decision_types(result)).to eq([ "merge" ])
    end

    %i[owner_approved checks_green mergeable
       review_feedback_clear blocking_reviews_complete reviews_fresh].each do |field|
      it "returns noop for human PR when #{field} is false" do
        signals = Automation::Strategies::AutoMerge::Signals.build(
          **all_human_preconditions.merge(field => false)
        )
        result = evaluate_auto_merge(signals: signals)

        expect(decision_types(result)).to eq([ "noop" ])
      end
    end

    it "bot PR requires only dependabot_eligible, checks_green, mergeable" do
      signals = Automation::Strategies::AutoMerge::Signals.build(
        issue_id: 42, pr_number: 10,
        bot_authored: true, dependabot_eligible: true,
        checks_green: true, mergeable: true,
        owner_approved: false, review_feedback_clear: false
      )

      result = evaluate_auto_merge(signals: signals)
      expect(decision_types(result)).to eq([ "merge" ])
    end
  end

  # -- Context immutability parity --

  describe "Context metadata immutability" do
    it "freezes metadata on construction" do
      context = Automation::Context.build(
        record: pull_request,
        project: project,
        metadata: { key: "value" }
      )

      expect(context.metadata).to be_frozen
    end

    it "with_metadata returns a new context without mutating the original" do
      original = Automation::Context.build(
        record: pull_request,
        project: project,
        metadata: { a: 1 }
      )

      extended = original.with_metadata(b: 2)

      expect(original.metadata).to eq({ a: 1 })
      expect(extended.metadata).to include(a: 1, b: 2)
    end
  end

  # -- Outcome blocking semantics parity --

  describe "Outcome blocking/sidecar semantics" do
    it "pending defaults to non-blocking (sidecar)" do
      outcome = Automation::Strategies::AutoReview::Outcome.pending(method: :copilot)

      expect(outcome).to be_pending
      expect(outcome).to be_sidecar
      expect(outcome).not_to be_blocking
    end

    it "retryable_failure defaults to blocking" do
      outcome = Automation::Strategies::AutoReview::Outcome.retryable_failure(method: :paid_agent)

      expect(outcome).to be_retryable_failure
      expect(outcome).to be_blocking
    end

    it "satisfied is never blocking" do
      outcome = Automation::Strategies::AutoReview::Outcome.satisfied(method: :copilot)

      expect(outcome).to be_satisfied
      expect(outcome).not_to be_blocking
    end

    it "not_applicable is never blocking" do
      outcome = Automation::Strategies::AutoReview::Outcome.not_applicable(method: :codex)

      expect(outcome).to be_not_applicable
      expect(outcome).not_to be_blocking
    end
  end
  end
end
