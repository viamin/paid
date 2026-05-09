# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationDecision do
  subject(:orchestration_decision) { build(:orchestration_decision) }

  describe "associations" do
    it { is_expected.to belong_to(:project).without_validating_presence }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:strategy_version).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:decision_type) }
    it { is_expected.to validate_length_of(:decision_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:actor) }
    it { is_expected.to validate_length_of(:actor).is_at_most(100) }

    it "derives the project from the agent run when omitted" do
      agent_run = create(:agent_run, :completed)
      decision = build(:orchestration_decision, agent_run: agent_run, project: nil)

      expect(decision).to be_valid
      expect(decision.project).to eq(agent_run.project)
    end

    it "rejects a project from a different agent run" do
      agent_run = create(:agent_run, :completed)
      other_project = create(:project)
      decision = build(:orchestration_decision, agent_run: agent_run, project: other_project)

      expect(decision).not_to be_valid
      expect(decision.errors[:project]).to include("must match the agent run's project")
    end

    it "allows a global strategy version" do
      skip "strategy_version_id column not present" unless ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
      strategy_version = create(:strategy_version, strategy: create(:strategy, :global))
      decision = build(:orchestration_decision, strategy_version: strategy_version)

      expect(decision).to be_valid
    end

    it "allows an account-scoped strategy version for the same account" do
      skip "strategy_version_id column not present" unless ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
      project = create(:project)
      strategy = create(:strategy, account: project.account, project: nil)
      strategy_version = create(:strategy_version, strategy: strategy)
      decision = build(:orchestration_decision, :without_agent_run, project: project, strategy_version: strategy_version)

      expect(decision).to be_valid
    end

    it "rejects a strategy version from another account" do
      skip "strategy_version_id column not present" unless ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
      project = create(:project)
      other_account_strategy = create(:strategy, :for_account)
      strategy_version = create(:strategy_version, strategy: other_account_strategy)
      decision = build(:orchestration_decision, :without_agent_run, project: project, strategy_version: strategy_version)

      expect(decision).not_to be_valid
      expect(decision.errors[:strategy_version]).to include("must be global or scoped to the decision's account/project")
    end

    it "rejects a strategy version scoped to a different project" do
      skip "strategy_version_id column not present" unless ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
      project = create(:project)
      other_project = create(:project, account: project.account)
      strategy = create(:strategy, project: other_project, account: project.account)
      strategy_version = create(:strategy_version, strategy: strategy)
      decision = build(:orchestration_decision, :without_agent_run, project: project, strategy_version: strategy_version)

      expect(decision).not_to be_valid
      expect(decision.errors[:strategy_version]).to include("must be global or scoped to the decision's account/project")
    end

    it "requires context to be an object" do
      decision = build(:orchestration_decision, context: [])

      expect(decision).not_to be_valid
      expect(decision.errors[:context]).to include("must be an object")
    end

    it "requires inputs to be an object" do
      decision = build(:orchestration_decision, inputs: "parallel")

      expect(decision).not_to be_valid
      expect(decision.errors[:inputs]).to include("must be an object")
    end

    it "requires outputs to be an object" do
      decision = build(:orchestration_decision, outputs: nil)

      expect(decision).not_to be_valid
      expect(decision.errors[:outputs]).to include("must be an object")
    end

    it "requires outcome_references to be an array" do
      decision = build(:orchestration_decision, outcome_references: {})

      expect(decision).not_to be_valid
      expect(decision.errors[:outcome_references]).to include("must be an array")
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, :completed, project: project) }

    describe ".for_project" do
      it "returns decisions for the given project" do
        decision = create(:orchestration_decision, project: project, agent_run: agent_run)
        create(:orchestration_decision)

        expect(described_class.for_project(project)).to eq([ decision ])
      end
    end

    describe ".for_agent_run" do
      it "returns decisions for the given agent run" do
        decision = create(:orchestration_decision, project: project, agent_run: agent_run)
        create(:orchestration_decision, :without_agent_run, project: project)

        expect(described_class.for_agent_run(agent_run)).to eq([ decision ])
      end
    end

    describe ".by_decision_type" do
      it "filters by decision type" do
        decision = create(:orchestration_decision, decision_type: "parallelize")
        create(:orchestration_decision, decision_type: "retry")

        expect(described_class.by_decision_type("parallelize")).to eq([ decision ])
      end
    end

    describe ".by_actor" do
      it "filters by actor" do
        decision = create(:orchestration_decision, actor: "planner")
        create(:orchestration_decision, actor: "workflow")

        expect(described_class.by_actor("planner")).to eq([ decision ])
      end
    end

    describe ".recent" do
      it "orders newest first" do
        older = create(:orchestration_decision, created_at: 1.hour.ago)
        newer = create(:orchestration_decision, created_at: 1.minute.ago)

        expect(described_class.recent).to eq([ newer, older ])
      end

      it "uses id as a deterministic tiebreaker for identical timestamps" do
        timestamp = Time.current.change(usec: 0)
        earlier = create(:orchestration_decision, created_at: timestamp)
        later = create(:orchestration_decision, created_at: timestamp)

        expect(described_class.recent).to eq([ later, earlier ])
      end
    end
  end

  describe "JSONB storage" do
    it "persists structured decision fields" do
      decision = create(:orchestration_decision)
      reloaded = described_class.find(decision.id)

      expect(reloaded.context).to eq(decision.context.deep_stringify_keys)
      expect(reloaded.inputs).to eq(decision.inputs.deep_stringify_keys)
      expect(reloaded.outputs).to eq(decision.outputs.deep_stringify_keys)
      expect(reloaded.outcome_references).to eq(decision.outcome_references.map(&:stringify_keys))
    end
  end
end
