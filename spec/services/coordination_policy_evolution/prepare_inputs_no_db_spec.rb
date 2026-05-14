# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyEvolution::PrepareInputs, :no_db do
  let(:account) { Struct.new(:id).new(1) }
  let(:service) { described_class.new(account: account, policy_type: "escalation", min_decisions: 1) }
  let(:status_counts) do
    {
      "applied" => 1,
      "deferred" => 1,
      "resolved" => 1
    }
  end

  describe "orchestration status classification" do
    before do
      relation = instance_double(ActiveRecord::Relation, count: 3)

      allow(service).to receive_messages(
        scoped_decisions: relation,
        orchestration_status_counts: status_counts,
        decision_type_counts: { "escalate" => 3 },
        policy_source_counts: {
          "defaults" => 2,
          "coordination_policy" => 1
        }
      )
    end

    it "classifies applied, deferred, and resolved escalation decisions as successes" do
      summary = service.send(:orchestration_performance_summary)

      expect(summary).to include(
        decision_count: 3,
        classified_decision_count: 3,
        success_count: 3,
        failure_count: 0,
        noop_count: 0,
        success_rate: 1.0
      )
    end

    it "keeps deferred and resolved decisions in the raw outcome counts" do
      summary = service.send(:orchestration_performance_summary)

      expect(summary[:outcome_counts]).to include(
        "applied" => 1,
        "deferred" => 1,
        "resolved" => 1
      )
    end

    it "samples all escalation success statuses as successes" do
      scoped = instance_double(ActiveRecord::Relation)
      successful = instance_double(ActiveRecord::Relation)
      sampled = [ Object.new ]

      allow(service).to receive(:scoped_decisions).and_return(scoped)
      allow(scoped).to receive(:where)
        .with(
          "COALESCE(context->>'decision_status', ?) IN (?)",
          "applied",
          OrchestrationDecision::SUCCESS_STATUSES
        )
        .and_return(successful)
      allow(successful).to receive(:order).with(created_at: :desc, id: :desc).and_return(successful)
      allow(successful).to receive(:limit).with(5).and_return(sampled)

      expect(service.send(:sample_successes)).to eq(sampled)
    end

    it "treats missing decision statuses as applied for historical orchestration records" do
      scoped = instance_double(ActiveRecord::Relation)
      successful = instance_double(ActiveRecord::Relation)

      allow(service).to receive(:scoped_decisions).and_return(scoped)
      allow(scoped).to receive(:where)
        .with(
          "COALESCE(context->>'decision_status', ?) IN (?)",
          "applied",
          OrchestrationDecision::SUCCESS_STATUSES
        )
        .and_return(successful)

      expect(service.send(:successful_decisions)).to eq(successful)
    end
  end

  describe "escalation configuration extraction" do
    it "reconstructs escalation config from persisted top-level rules and parameters" do
      configuration = service.send(
        :effective_configuration,
        {
          "explicit_triggers" => %w[operational_failure_breaker],
          "auto_resolve_trigger_types" => %w[owner_approved]
        },
        {
          "human_value_threshold" => 0.45,
          "weights" => { "review_goal_retry_pressure" => 0.6 },
          "interruption_cost" => { "base" => 0.2 }
        }
      )

      expect(configuration.fetch("escalation")).to include(
        "human_value_threshold" => 0.45,
        "explicit_triggers" => %w[operational_failure_breaker],
        "auto_resolve_trigger_types" => %w[owner_approved],
        "weights" => { "review_goal_retry_pressure" => 0.6 },
        "interruption_cost" => { "base" => 0.2 }
      )
    end
  end

  describe "legacy decomposition config extraction" do
    it "accepts flat decomposition_enabled fields from older strategy snapshots" do
      decomposition_service = described_class.new(account: account, policy_type: "decomposition")

      configuration = decomposition_service.send(
        :effective_configuration,
        {
          "decomposition_enabled" => false,
          "min_components_to_decompose" => 4
        },
        {
          "max_tasks" => 10
        }
      )

      expect(configuration.fetch("decomposition")).to include(
        "enabled" => false,
        "min_components_to_decompose" => 4,
        "max_tasks" => 10
      )
    end
  end

  describe "policy provenance serialization" do
    it "symbolizes provenance keys from persisted metadata" do
      provenance = service.send(
        :policy_provenance,
        {
          "policy_source" => "coordination_policy",
          "policy_key" => "feature_decomposition",
          "coordination_policy_id" => 12,
          "coordination_policy_version_id" => 34,
          "coordination_policy_version" => 5
        }
      )

      expect(provenance).to include(
        policy_source: "coordination_policy",
        policy_key: "feature_decomposition",
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      )
      expect(provenance.keys).to all(be_a(Symbol))
    end

    it "extracts provenance from symbol-keyed metadata" do
      provenance = service.send(
        :policy_provenance,
        {
          policy_source: "coordination_policy",
          policy_key: "feature_decomposition",
          coordination_policy_id: 12,
          coordination_policy_version_id: 34,
          coordination_policy_version: 5
        }
      )

      expect(provenance).to include(
        policy_source: "coordination_policy",
        policy_key: "feature_decomposition",
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      )
    end
  end

  describe "unsupported policy types" do
    it "fails fast instead of falling back to decomposition inputs" do
      expect {
        described_class.new(account: account, policy_type: "lifecycle_state")
      }.to raise_error(ArgumentError, 'unsupported coordination policy type: "lifecycle_state"')
    end
  end
end
