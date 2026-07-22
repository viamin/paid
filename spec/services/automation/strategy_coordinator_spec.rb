# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::StrategyCoordinator do
  let(:project) { create(:project) }
  let(:coordinator) { described_class.new(project: project) }

  describe "#evaluate" do
    it "evaluates each selected strategy and deduplicates merge decisions" do
      merge_decision = Automation::Decision.merge(issue_id: 12, pr_number: 42)
      auto_continue = instance_double(Automation::Strategies::AutoContinue)
      auto_merge = instance_double(Automation::Strategies::AutoMerge)
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_continue, project: project)
        .and_return(auto_continue)
      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_merge, project: project)
        .and_return(auto_merge)
      allow(auto_continue).to receive(:evaluate)
        .with(context)
        .and_return(Automation::Result.new(decisions: [ merge_decision ]))
      allow(auto_merge).to receive(:evaluate)
        .with(context)
        .and_return(Automation::Result.new(decisions: [ merge_decision ]))

      result = coordinator.evaluate(context:, strategy_types: %i[auto_continue auto_merge])

      expect(result.decisions).to eq([ merge_decision ])
    end

    it "resolves conflicts so a merge decision suppresses other strategies' decisions" do
      merge_decision = Automation::Decision.merge(issue_id: 12, pr_number: 42)
      followup = Automation::Decision.queue_create_pr_run(
        issue_id: 12, source_pull_request_number: 42
      )
      auto_continue = instance_double(Automation::Strategies::AutoContinue)
      auto_merge = instance_double(Automation::Strategies::AutoMerge)
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_continue, project: project)
        .and_return(auto_continue)
      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_merge, project: project)
        .and_return(auto_merge)
      allow(auto_continue).to receive(:evaluate)
        .and_return(Automation::Result.new(decisions: [ followup ]))
      allow(auto_merge).to receive(:evaluate)
        .and_return(Automation::Result.new(decisions: [ merge_decision ]))

      result = coordinator.evaluate(context:, strategy_types: %i[auto_continue auto_merge])

      # Merge trumps continue (RDR-023 conflict resolution): the follow-up
      # run is suppressed so the PR is merged rather than reworked.
      expect(result.decisions).to eq([ merge_decision ])
    end

    it "preserves distinct non-merge decisions when no conflict exists" do
      followup = Automation::Decision.queue_create_pr_run(
        issue_id: 12, source_pull_request_number: 42
      )
      auto_review = instance_double(Automation::Strategies::AutoReview)
      auto_continue = instance_double(Automation::Strategies::AutoContinue)
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_review, project: project)
        .and_return(auto_review)
      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_continue, project: project)
        .and_return(auto_continue)
      allow(auto_review).to receive(:evaluate)
        .and_return(Automation::Result.new(decisions: [ followup ]))
      allow(auto_continue).to receive(:evaluate)
        .and_return(Automation::Result.new(decisions: [ Automation::Decision.noop ]))

      result = coordinator.evaluate(context:, strategy_types: %i[auto_review auto_continue])

      expect(result.decisions).to contain_exactly(followup, Automation::Decision.noop)
    end
  end

  describe "#evaluate_pull_request" do
    it "builds a context for the record and runs the requested strategies" do
      pull_request = create(:issue, :pull_request, project: project, github_number: 42)
      strategy = instance_double(Automation::Strategies::AutoContinue)
      result = Automation::Result.noop

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_continue, project: project)
        .and_return(strategy)
      allow(strategy).to receive(:evaluate).and_return(result)

      coordinator.evaluate_pull_request(
        record: pull_request,
        metadata: { scan: { issue_id: pull_request.id, pr_number: 42, triggers: [] } },
        strategy_types: %i[auto_continue]
      )

      expect(strategy).to have_received(:evaluate).with(
        have_attributes(project: project, record: pull_request)
      )
    end
  end

  describe "DB-backed strategy selection" do
    def create_strategy_for(decision_type, content: {}, selection_rules: {})
      strategy = create(:strategy, :global, decision_type: decision_type, selection_rules: selection_rules)
      reviewer = create(:user)
      version = strategy.create_version!(
        content: content,
        provenance: { "source" => "test" },
        promotion_state: "active",
        created_by: "test",
        promoted_at: Time.current,
        promoted_by_user: reviewer
      )
      strategy.update!(current_version: version)
      strategy
    end

    def ready_phase_selection_rules
      {
        "phase" => "ready",
        "metadata" => {
          "scan" => {
            "phase" => "ready"
          }
        }
      }
    end

    def ready_phase_context_for(pull_request)
      Automation::Context.build(
        record: pull_request,
        project: project,
        metadata: {
          scan: {
            issue_id: pull_request.id,
            pr_number: pull_request.github_number,
            phase: "ready",
            triggers: [ { type: "changes_requested" } ]
          },
          lifecycle: {
            issue_id: pull_request.id,
            pr_number: pull_request.github_number,
            phase: "ready",
            draft: false
          }
        }
      )
    end

    before do
      allow(Automation::Strategies::Select).to receive(:call).and_return(
        instance_double(Automation::Strategies::AutoContinue, evaluate: Automation::Result.noop)
      )
    end

    it "logs an OrchestrationDecision for each strategy type evaluated" do
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      coordinator.evaluate(context:, strategy_types: %i[auto_continue auto_merge])

      expect(OrchestrationDecision.where(project: project, decision_type: "auto_continue")).to exist
      expect(OrchestrationDecision.where(project: project, decision_type: "auto_merge")).to exist
    end

    it "links the matched strategy version in the OrchestrationDecision" do
      strategy = create_strategy_for("auto_continue", content: { "max_retries" => 3 })
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      coordinator.evaluate(context:, strategy_types: %i[auto_continue])

      decision = OrchestrationDecision.find_by(project: project, decision_type: "auto_continue")
      expect(decision.strategy_version).to eq(strategy.current_version)
      expect(decision.context["decision_status"]).to eq("applied")
      expect(decision.outputs).to eq({ "max_retries" => 3 })
    end

    it "selects against PR runtime context and records that context in the decision inputs" do
      pull_request = create(:issue, :pull_request, project: project, github_number: 42, labels: [ "paid" ])
      strategy = create_strategy_for(
        "auto_continue",
        content: { "mode" => "ready-phase" },
        selection_rules: ready_phase_selection_rules
      )
      context = ready_phase_context_for(pull_request)

      coordinator.evaluate(context:, strategy_types: %i[auto_continue])

      decision = OrchestrationDecision.find_by!(project: project, decision_type: "auto_continue")
      expect(decision.strategy_version).to eq(strategy.current_version)
      expect(decision.inputs).to include(
        "record_type" => "Issue",
        "record_id" => pull_request.id,
        "github_number" => pull_request.github_number,
        "phase" => "ready",
        "draft" => false,
        "labels" => [ "paid" ],
        "trigger_types" => [ "changes_requested" ]
      )
      expect(decision.inputs.dig("metadata", "scan", "phase")).to eq("ready")
    end

    it "logs noop status when no DB strategy matches" do
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      coordinator.evaluate(context:, strategy_types: %i[auto_merge])

      decision = OrchestrationDecision.find_by(project: project, decision_type: "auto_merge")
      expect(decision.context["decision_status"]).to eq("noop")
      expect(decision.strategy_version).to be_nil
    end

    it "does not raise when DB strategy selection fails" do
      allow(Strategies::Select).to receive(:call).and_raise(RuntimeError, "db unavailable")
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      expect { coordinator.evaluate(context:, strategy_types: %i[auto_continue]) }.not_to raise_error
    end
  end
end
