# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::PullRequestEvaluator do
  describe "#call" do
    let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
    let(:pull_request) do
      create(:issue, :pull_request,
        project: project,
        labels: [ "paid-build" ],
        paid_state: "new",
        github_number: 42)
    end

    it "keeps legacy initial-sync create_pr behavior when the flag is disabled" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: false).call

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_create_pr_run",
            issue_id: pull_request.id,
            source_pull_request_number: 42
          }
        ]
      )
    end

    it "returns noop for initial-sync PR evaluation when the flag is enabled" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call

      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end

    it "selects auto-continue through Automation::Strategies::Select for explicit PR decisions" do
      selected_strategy = instance_double(Automation::Strategies::AutoContinue)
      result = Automation::Result.noop

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_continue, project: project)
        .and_return(selected_strategy)
      allow(selected_strategy).to receive(:evaluate).and_return(result)

      described_class.new(record: pull_request, explicit_pr_decisions: true).call(
        scan: { issue_id: pull_request.id, pr_number: 42, phase: "ready", triggers: [] }
      )

      expect(Automation::Strategies::Select).to have_received(:call)
        .with(strategy_type: :auto_continue, project: project)
      expect(selected_strategy).to have_received(:evaluate).with(
        have_attributes(project: project, record: pull_request)
      )
    end

    it "maps paid_agent review signals to an explicit review decision" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "paid_agent_review_pending" } ]
      })

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_review_run",
            issue_id: pull_request.id,
            source_pull_request_number: 42,
            focus: "general"
          }
        ]
      )
    end

    it "suppresses create_pr followup when paid_agent_review_pending coexists with other triggers (#1135)" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_draft_review_count: 0,
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "ci_failure", details: [ "test-suite" ] }
        ]
      })

      decision_types = result.to_h[:decisions].map { |d| d[:type] }
      expect(decision_types).to include("queue_review_run")
      expect(decision_types).not_to include("queue_create_pr_run")
    end

    it "forwards the review-bot fallback chain into the request_review decision" do
      chain = [ Activities::RequestReviewActivity::COPILOT_LOGIN,
                Activities::RequestReviewActivity::CODEX_LOGIN ]
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id, pr_number: 42, phase: "draft", current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending",
                      request_login: chain.first, request_logins: chain } ]
      })

      request_decision = result.to_h[:decisions].find { |d| d[:type] == "request_review" }
      expect(request_decision[:reviewers]).to eq(chain)
    end

    it "falls back to the legacy single request_login when request_logins is absent" do
      # Backward compatibility for in-flight workflow histories whose recorded
      # scan output pre-dates the chain field.
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "draft",
        current_draft_review_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN }
        ]
      })

      request_decision = result.to_h[:decisions].find { |d| d[:type] == "request_review" }
      expect(request_decision[:reviewers]).to eq([ Activities::RequestReviewActivity::COPILOT_LOGIN ])
    end

    it "suppresses create_pr followup even with active_run and multiple triggers (#1135)" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "paid_agent_review_pending", active_run: true },
          { type: "merge_conflicts", details: "PR has merge conflicts" },
          { type: "conversation_comments", details: "3 new comment(s)" }
        ]
      })

      decision_types = result.to_h[:decisions].map { |d| d[:type] }
      expect(decision_types).not_to include("queue_create_pr_run")
      expect(decision_types).not_to include("record_pr_followup")
    end
  end

  # Regression coverage for PR #1077: the evaluator must distinguish between
  # initial label-based sync of an existing PR (which should never implicitly
  # queue a create_pr) and PR follow-up scanning (which produces explicit goal
  # decisions based on scan triggers).
  describe "#1077 regression: initial sync vs PR follow-up decision paths" do
    let(:project) do
      create(:project,
        label_mappings: { "build" => "paid-build", "plan" => "paid-plan" },
        automation_on_label_enabled: true,
        automation_label_name: "paid-automation")
    end

    context "with an initial sync of an existing PR (no scan payload)" do
      it "returns noop for an automation-labeled PR when the explicit flag is enabled" do
        pr = create(:issue, :pull_request,
          project: project, labels: [ "paid-automation" ], paid_state: "new", github_number: 7)

        result = described_class.new(record: pr, explicit_pr_decisions: true).call

        expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
      end

      it "returns noop for a completed PR with generated+automation labels (PR #1077 scenario)" do
        pr = create(:issue, :pull_request,
          project: project,
          labels: [ project.generated_label_name, project.automation_label_name ],
          paid_state: "completed",
          github_number: 42)

        result = described_class.new(record: pr, explicit_pr_decisions: true).call

        expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
      end
    end

    context "with a PR follow-up scan carrying actionable signals (explicit goal path)" do
      let(:pr) { create(:issue, :pull_request, project: project, github_number: 42) }

      it "emits queue_create_pr_run with source_pull_request_number for ready-phase CI failure" do
        result = described_class.new(record: pr, explicit_pr_decisions: true).call(scan: {
          issue_id: pr.id,
          pr_number: 42,
          phase: "ready",
          current_followup_count: 0,
          labels_to_remove: [],
          triggers: [ { type: "ci_failure", details: [ "rspec" ] } ]
        })

        decisions = result.to_h[:decisions]
        create_decision = decisions.find { |d| d[:type] == "queue_create_pr_run" }
        expect(create_decision).to include(issue_id: pr.id, source_pull_request_number: 42, focus: "general")
        expect(decisions.map { |d| d[:type] }).to include("record_pr_followup")
      end

      it "emits queue_create_pr_run tagged for draft round tracking on draft-phase follow-ups" do
        result = described_class.new(record: pr, explicit_pr_decisions: true).call(scan: {
          issue_id: pr.id,
          pr_number: 42,
          phase: "draft",
          current_draft_review_count: 1,
          triggers: [ { type: "merge_conflicts", details: "PR has merge conflicts" } ]
        })

        decisions = result.to_h[:decisions]
        create_decision = decisions.find { |d| d[:type] == "queue_create_pr_run" }
        expect(create_decision).to include(
          issue_id: pr.id,
          source_pull_request_number: 42,
          focus: "general",
          count_toward_draft_review_round: true,
          expected_draft_review_count: 1
        )
      end
    end

    context "with a PR follow-up scan carrying only review signals (review-only path)" do
      let(:pr) { create(:issue, :pull_request, project: project, github_number: 42) }

      it "queues a review run and does NOT queue a default create_pr" do
        result = described_class.new(record: pr, explicit_pr_decisions: true).call(scan: {
          issue_id: pr.id,
          pr_number: 42,
          phase: "draft",
          current_draft_review_count: 0,
          triggers: [ { type: "paid_agent_review_pending" } ]
        })

        decision_types = result.to_h[:decisions].map { |d| d[:type] }
        expect(decision_types).to eq([ "queue_review_run" ])
        expect(decision_types).not_to include("queue_create_pr_run")
      end
    end
  end
end
