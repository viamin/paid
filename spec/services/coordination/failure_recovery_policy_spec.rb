# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecoveryPolicy do
  describe ".call" do
    let(:project) { create(:project) }

    it "returns the default recovery policy when no coordination policy exists" do
      result = described_class.call(project: project)

      expect(result).to include(
        "source" => "defaults",
        "policy_key" => "failure_recovery",
        "default_action" => "pause_and_notify"
      )
      expect(result["actions"]).to include(
        "timeout" => "retry_same_runner",
        "dependency_failure" => "cancel_workflow"
      )
    end

    it "uses the active account policy when present" do
      policy = create(:coordination_policy, :active,
        account: project.account,
        policy_type: "recovery",
        policy_key: "failure_recovery")
      policy.current_version.update!(
        rules: { "failure_actions" => { "timeout" => "escalate_model" } },
        parameters: { "default_action" => "skip_and_continue" }
      )

      result = described_class.call(project: project)

      expect(result).to include(
        "source" => "coordination_policy",
        "coordination_policy_id" => policy.id,
        "coordination_policy_version_id" => policy.current_version.id
      )
      expect(result["actions"]["timeout"]).to eq("escalate_model")
      expect(result["default_action"]).to eq("skip_and_continue")
    end

    it "prefers a project-scoped policy over an account-scoped one" do
      create(:coordination_policy, :active,
        account: project.account,
        policy_type: "recovery",
        policy_key: "failure_recovery").tap do |policy|
        policy.current_version.update!(rules: { "failure_actions" => { "timeout" => "pause_and_notify" } })
      end

      scoped_policy = create(:coordination_policy, :active, :project_scoped,
        account: project.account,
        project: project,
        policy_type: "recovery",
        policy_key: "failure_recovery")
      scoped_policy.current_version.update!(rules: { "failure_actions" => { "timeout" => "escalate_model" } })

      result = described_class.call(project: project)

      expect(result["coordination_policy_id"]).to eq(scoped_policy.id)
      expect(result["actions"]["timeout"]).to eq("escalate_model")
    end

    it "applies explicit overrides ahead of stored policies" do
      result = described_class.call(project: project, overrides: { "timeout" => "escalate_model" })

      expect(result).to include(
        "source" => "override",
        "coordination_policy_id" => nil
      )
      expect(result["actions"]["timeout"]).to eq("escalate_model")
    end
  end
end
