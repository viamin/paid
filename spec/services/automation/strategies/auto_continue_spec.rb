# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue do
  let(:strategy) { described_class.new }
  let(:project) { create(:project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, paid_state: "new")
  end

  def evaluate(lifecycle: nil, scan: nil)
    metadata = {}
    metadata[:lifecycle] = lifecycle if lifecycle
    metadata[:scan] = scan if scan

    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: metadata
    )
    strategy.evaluate(context)
  end

  def decision_types(result)
    result.to_h[:decisions].map { |d| d[:type] }
  end

  def ready_scan_payload
    {
      issue_id: pull_request.id,
      pr_number: 42,
      phase: "ready",
      triggers: []
    }
  end

  it "is an Automation::Strategy" do
    expect(described_class.ancestors).to include(Automation::Strategy)
  end

  describe "an already-escalated PR" do
    # @spec PR-ESCALATION-001
    it "decides nothing when the scan reports no recovery signal" do
      signals = {
        issue_id: 1,
        pr_number: 42,
        phase: "escalated",
        pr_auto_continue_token_limit_reached: true,
        failure_streak_limit_reached: true,
        no_progress_stuck: true,
        escalation_reason: "Token cap reached",
        escalation_reason_key: Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT
      }
      context = Automation::Context.new(record: nil, project: project, metadata: { lifecycle: signals })

      result = described_class.new.evaluate(context)

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
    end

    # @spec PR-ESCALATION-009
    it "still acts on a recovery signal from the scan" do
      signals = {
        issue_id: 1,
        pr_number: 42,
        phase: "escalated",
        draft: false,
        scan: { triggers: [ { type: "dismiss_escalation", owner_initiated: true } ] }
      }
      context = Automation::Context.new(record: nil, project: project, metadata: {
        lifecycle: signals,
        scan: { triggers: [ { type: "dismiss_escalation", owner_initiated: true } ] }
      })

      result = described_class.new.evaluate(context)

      expect(result.decisions.map(&:type)).to include("dismiss_escalation")
    end
  end

  describe "backwards compatibility" do
    it "selects auto-review through Automation::Strategies::Select when lifecycle signals are absent" do
      selected_strategy = instance_double(Automation::Strategies::AutoReview)
      context = Automation::Context.build(
        record: pull_request,
        project: project,
        metadata: { scan: ready_scan_payload }
      )

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_review, project: project)
        .and_return(selected_strategy)
      allow(selected_strategy).to receive(:evaluate).and_return(Automation::Result.noop)

      strategy.evaluate(context)

      expect(Automation::Strategies::Select).to have_received(:call)
        .with(strategy_type: :auto_review, project: project)
      expect(selected_strategy).to have_received(:evaluate).with(
        have_attributes(project: project, record: pull_request)
      )
    end

    it "delegates to AutoReview when no lifecycle signals are present" do
      result = evaluate(scan: ready_scan_payload.merge(triggers: [ { type: "owner_approved" } ]))

      expect(result.to_h[:decisions].first).to include(type: "merge")
    end

    it "returns noop when neither lifecycle nor scan is provided" do
      result = evaluate
      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end
  end

  describe "lifecycle gates" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        active_run_exists: false,
        operational_failure_breaker: false,
        no_progress_stuck: false,
        failure_streak_limit_reached: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        draft: false
      }
    end

    context "when an active run exists" do
      it "returns noop" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(active_run_exists: true),
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end

      # @spec FOCUSED-RUN-007
      it "escalates when the PR token cap is reached" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            active_run_exists: true,
            pr_auto_continue_token_limit_reached: true,
            pr_auto_continue_tokens_used: 154_385_596,
            pr_auto_continue_token_limit: 50_000_000,
            escalation_reason: "PR auto-continue token limit reached (154385596/50000000 recorded tokens)",
            escalation_reason_key: "pr_auto_continue_token_limit"
          )
        )

        expect(result.to_h[:decisions].first).to include(
          type: "escalate",
          issue_id: pull_request.id,
          reason_key: "pr_auto_continue_token_limit",
          reason: "PR auto-continue token limit reached (154385596/50000000 recorded tokens)"
        )
      end
    end

    context "when operational failure breaker trips" do
      it "returns an escalate decision" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            operational_failure_breaker: true,
            no_progress_stuck: true,
            escalation_reason: "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"
          )
        )

        decisions = result.to_h[:decisions]
        expect(decisions.first).to include(
          type: "escalate",
          issue_id: pull_request.id,
          pr_number: 42,
          owner_reviewer_login: "alice",
          reason: "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"
        )
      end
    end

    context "when in draft phase" do
      let(:draft_lifecycle) { base_lifecycle.merge(phase: "draft", draft: true) }

      it "escalates when the unified failure streak limit is reached for draft-phase runs" do
        result = evaluate(
          lifecycle: draft_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(
          type: "escalate",
          reason: "Automatic PR failure streak reached"
        )
      end
    end

    context "when in restarted phase" do
      let(:restarted_lifecycle) { base_lifecycle.merge(phase: "restarted", draft: true) }

      it "escalates when the unified failure streak limit is reached" do
        result = evaluate(
          lifecycle: restarted_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end
    end

    context "when in ready phase" do
      it "escalates when the unified failure streak limit is reached" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          )
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "delegates to AutoReview when a review-goal retry is pending" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: false,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          ),
          scan: {
            issue_id: pull_request.id,
            pr_number: 42,
            phase: "ready",
            current_review_goal_retry_count: 1,
            triggers: [ { type: "review_goal_retry" } ]
          }
        )

        expect(decision_types(result)).to eq([ "queue_review_run", "record_review_goal_retry" ])
      end

      it "delegates to AutoReview when review feedback is already pending" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: false,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          ),
          scan: {
            issue_id: pull_request.id,
            pr_number: 42,
            phase: "ready",
            triggers: [ { type: "changes_requested" } ]
          }
        )

        expect(decision_types(result)).to eq([ "queue_create_pr_run", "record_pr_followup" ])
      end

      it "escalates instead of queuing another create_pr follow-up once review feedback is stuck" do # @spec FOCUSED-RUN-006
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          ),
          scan: {
            issue_id: pull_request.id,
            pr_number: 42,
            phase: "ready",
            triggers: [ { type: "changes_requested" } ]
          }
        )

        expect(result.to_h[:decisions].first).to include(type: "escalate")
      end

      it "still delegates when a review run is pending" do
        result = evaluate(
          lifecycle: base_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          ),
          scan: {
            issue_id: pull_request.id,
            pr_number: 42,
            phase: "ready",
            triggers: [ { type: "paid_agent_review_pending" } ]
          }
        )

        expect(decision_types(result)).to eq([ "queue_review_run" ])
      end

      it "delegates to AutoReview when no unified gate is active" do
        result = evaluate(
          lifecycle: base_lifecycle,
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "queue_create_pr_run", "record_pr_followup" ])
      end
    end

    context "when in escalated phase" do
      let(:escalated_lifecycle) { base_lifecycle.merge(phase: "escalated") }

      # @spec PR-ESCALATION-001
      it "does not re-escalate a PR that is already escalated" do
        result = evaluate(
          lifecycle: escalated_lifecycle.merge(
            failure_streak_limit_reached: true,
            no_progress_stuck: true,
            consecutive_unsuccessful_automatic_runs: 3,
            escalation_reason: "Automatic PR failure streak reached"
          )
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end

      # @spec PR-ESCALATION-001
      it "queues no follow-up work when the scan reports no recovery trigger" do
        result = evaluate(
          lifecycle: escalated_lifecycle,
          scan: { issue_id: pull_request.id, pr_number: 42, phase: "escalated", triggers: [] }
        )

        expect(decision_types(result)).to eq([ "noop" ])
      end
    end
  end

  describe "delegation to AutoReview" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        active_run_exists: false,
        operational_failure_breaker: false,
        failure_streak_limit_reached: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        draft: false
      }
    end

    it "returns noop when gates pass but no scan data is present" do
      result = evaluate(lifecycle: base_lifecycle)

      expect(decision_types(result)).to eq([ "noop" ])
    end

    it "delegates to AutoReview when gates pass and scan data is present" do
      result = evaluate(
        lifecycle: base_lifecycle,
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          triggers: [ { type: "owner_approved" } ]
        }
      )

      expect(result.to_h[:decisions].first).to include(type: "merge")
    end

    it "delegates follow-up decisions through AutoReview" do
      result = evaluate(
        lifecycle: base_lifecycle,
        scan: {
          issue_id: pull_request.id,
          pr_number: 42,
          phase: "ready",
          current_followup_count: 0,
          labels_to_remove: [],
          triggers: [ { type: "ci_failure", details: "test-suite" } ]
        }
      )

      types = decision_types(result)
      expect(types).to include("queue_create_pr_run", "record_pr_followup")
    end
  end

  describe "gate priority" do
    let(:base_lifecycle) do
      {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        active_run_exists: false,
        operational_failure_breaker: false,
        no_progress_stuck: false,
        failure_streak_limit_reached: false,
        owner_reviewer_login: "alice",
        escalation_reason: nil,
        consecutive_unsuccessful_automatic_runs: 0,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        draft: true
      }
    end

    it "active_run_exists takes priority over breakers" do
      result = evaluate(
        lifecycle: base_lifecycle.merge(
          active_run_exists: true,
          operational_failure_breaker: true,
          no_progress_stuck: true,
          escalation_reason: "Consecutive operational failures"
        ),
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "draft", triggers: [] }
      )

      expect(decision_types(result)).to eq([ "noop" ])
    end
  end
end
