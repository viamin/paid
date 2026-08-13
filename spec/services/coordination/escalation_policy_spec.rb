# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::EscalationPolicy, :no_db do
  before do
    stub_const("EscalationPolicyProjectStub", Struct.new(:id, :account, keyword_init: true))
    stub_const("EscalationPolicyRecordStub", Struct.new(:policy_key, :id, keyword_init: true))
    stub_const("EscalationPolicyVersionStub", Struct.new(:rules, :parameters, :id, :version, keyword_init: true))
  end

  let(:project) { EscalationPolicyProjectStub.new(id: 7, account: Object.new) }
  let(:policy_record) do
    EscalationPolicyRecordStub.new(
      policy_key: Coordination::EscalationPolicy::POLICY_KEY,
      id: 11
    )
  end
  let(:current_version) do
    EscalationPolicyVersionStub.new(
      id: 29,
      version: 3,
      rules: {
        "explicit_triggers" => %w[operational_failure_breaker]
      },
      parameters: {
        "weights" => {
          "operational_failure_breaker" => 0.8
        }
      }
    )
  end

  def policy_for(version)
    described_class.new(project: project).tap do |policy|
      allow(policy).to receive_messages(
        policy: policy_record,
        current_version: version
      )
    end
  end

  it "replaces the legacy operational explicit trigger with no_progress_stuck" do
    result = policy_for(current_version).call

    expect(result["explicit_triggers"]).to eq([ "no_progress_stuck" ])
  end

  it "resets the legacy operational failure weight override to the default softer value" do
    result = policy_for(current_version).call

    expect(result.dig("weights", "operational_failure_breaker")).to eq(
      described_class::DEFAULT_POLICY.dig("weights", "operational_failure_breaker")
    )
  end

  it "preserves custom explicit triggers that do not rely on the legacy operational breaker" do
    result = policy_for(
      EscalationPolicyVersionStub.new(
        id: 30,
        version: 4,
        rules: {
          "explicit_triggers" => %w[review_goal_retry_limit_requires_escalation]
        },
        parameters: {}
      )
    ).call

    expect(result["explicit_triggers"]).to eq([ "review_goal_retry_limit_requires_escalation" ])
  end
end
