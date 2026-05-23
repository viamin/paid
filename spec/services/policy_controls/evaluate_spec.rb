# frozen_string_literal: true

require "rails_helper"

RSpec.describe PolicyControls::Evaluate do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, labels: [ "type:bug", "surface:schema" ]) }
  let(:runner) { create(:runner, user: project.created_by, runner_key: "codex") }
  let(:model) { create(:llm_model, :openai, model_id: "gpt-5.4", tier: "high") }
  let(:simulation_rules) do
    {
      "controls" => {
        "runner_allowlist" => [ "codex" ],
        "max_model_tier" => "mid",
        "prompt_redaction" => { "enabled" => true, "classify" => true, "block_fully_redacted" => true }
      },
      "risk_rules" => [
        { "name" => "schema_changes", "conditions" => { "change_surface_any" => [ "schema" ] }, "score" => 90 }
      ],
      "approval_rules" => [
        {
          "name" => "high_risk",
          "conditions" => { "risk_score_gte" => 80 },
          "workflow" => { "required" => true, "reason" => "Security review required", "approvers" => [ "security" ] }
        }
      ]
    }
  end

  describe ".call" do
    it "uses simulation rules without requiring a persisted policy" do
      result = evaluate(prompt: "api_key=abcdefghijklmnopqrstuvwx123456", context: { "change_surface" => [ "schema" ] }, simulation: true, rules: simulation_rules)

      expect(result.paused).to be(true)
      expect(result.allowed).to be(false)
      expect(result.violations).to include("model_tier_exceeds_maximum")
      expect(result.risk_score).to eq(90)
      expect(result.approval["required"]).to be(true)
      expect(result.approval["approvers"]).to eq([ "security" ])
      expect(result.sanitized_prompt).to include("[REDACTED:")
      expect(result.classification).to include(a_string_starting_with("contains:"))
      expect(result.policy_metadata["source"]).to eq("simulation")
    end

    it "applies environment-specific controls from the active execution policy" do
      direct_outbound_runner = pi_direct_outbound_runner
      policy = create_execution_policy(
        "controls" => { "service_containers" => { "mode" => "allow_attached" } },
        "environment_controls" => [
          {
            "name" => "production",
            "conditions" => { "branch" => "main" },
            "controls" => {
              "network_access" => "restricted",
              "max_model_tier" => "mid"
            }
          }
        ]
      )

      result = evaluate(runner: direct_outbound_runner, prompt: "Ship it")

      expect(result.matched_environment_controls).to eq([ "production" ])
      expect(result.context["environment"]).to eq("production")
      expect(result.controls["network_access"]).to eq("restricted")
      expect(result.violations).to include("network_access_not_allowed", "model_tier_exceeds_maximum")
      expect(result.policy_metadata["coordination_policy_id"]).to eq(policy.id)
    end

    it "requires approval for matched approval workflows without introducing hard violations" do
      create_execution_policy(
        "controls" => { "runner_allowlist" => [ "codex" ] },
        "risk_rules" => [
          { "name" => "bugfix", "conditions" => { "issue_labels_any" => [ "type:bug" ] }, "score" => 75 }
        ],
        "approval_rules" => [
          {
            "name" => "risk_gate",
            "conditions" => { "risk_score_gte" => 70 },
            "workflow" => { "required" => true, "reason" => "Owner approval required", "approvers" => [ "repo_owner" ] }
          }
        ]
      )

      low_tier_model = create(:llm_model, :openai, model_id: "gpt-5.4-mini", tier: "mid")
      result = evaluate(model: low_tier_model, prompt: "Implement the fix")

      expect(result.allowed).to be(true)
      expect(result.paused).to be(true)
      expect(result.violations).to be_empty
      expect(result.reason).to eq("Policy approval required: Owner approval required")
      expect(result.approval["matched_rules"]).to eq([ "risk_gate" ])
    end
  end

  def evaluate(**overrides)
    described_class.call(**{
      project: project,
      issue: issue,
      goal: "create_pr",
      runner: runner,
      model: model,
      prompt: "Implement the fix"
    }.merge(overrides))
  end

  def create_execution_policy(rules)
    create(:coordination_policy,
      :active,
      account: project.account,
      project: project,
      policy_type: "execution",
      policy_key: "agent_execution").tap do |policy|
      policy.current_version.update!(rules: rules)
    end
  end

  def pi_direct_outbound_runner
    create(
      :runner,
      user: project.created_by,
      runner_key: "pi",
      auth_type: "api_key",
      provider_api_key: create(:provider_api_key, user: project.created_by, api_service_type: "anthropic"),
      config: { "pi" => { "api_provider" => "anthropic", "model" => "claude-3-7-sonnet" } }
    )
  end
end
