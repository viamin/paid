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
        .with("COALESCE(context->>'decision_status', 'unknown') IN (?)", %w[applied deferred resolved])
        .and_return(successful)
      allow(successful).to receive(:order).with(created_at: :desc, id: :desc).and_return(successful)
      allow(successful).to receive(:limit).with(5).and_return(sampled)

      expect(service.send(:sample_successes)).to eq(sampled)
    end
  end
end
