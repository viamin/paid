# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::DetectBrokenRunnerModels do
  let(:project) { create(:project) }

  def failed_run(runners_attempted, updated_at: Time.current)
    run = create(:agent_run, project: project, status: "failed", runners_attempted: runners_attempted)
    run.update_column(:updated_at, updated_at)
    run
  end

  def model_not_found_attempt(runner:, model:)
    {
      "runner" => runner,
      "success" => false,
      "error_type" => "error",
      "error_message" => "\e[91mError: \e[0mModel not found: #{model}.\nProviderModelNotFoundError"
    }
  end

  def codex_outdated_attempt(model: "gpt-5.5")
    {
      "runner" => "codex",
      "success" => false,
      "error_type" => "error",
      "error_message" => "The '#{model}' model requires a newer version of Codex. Please upgrade."
    }
  end

  it "detects opencode model-not-found failures and extracts the model id" do
    failed_run([ model_not_found_attempt(runner: "runner:99", model: "moonshotai/kimi-k2") ])

    finding = described_class.call.findings.first

    expect(finding[:model]).to eq("moonshotai/kimi-k2")
    expect(finding[:error_type]).to eq(Models::DetectBrokenRunnerModels::MODEL_NOT_FOUND)
  end

  it "detects codex CLI-version-outdated failures and extracts the model" do
    failed_run([ codex_outdated_attempt(model: "gpt-5.5") ])

    finding = described_class.call.findings.first

    expect(finding[:model]).to eq("gpt-5.5")
    expect(finding[:error_type]).to eq(Models::DetectBrokenRunnerModels::CLI_VERSION_OUTDATED)
  end

  it "parses provider/model from a ProviderModelNotFoundError data block" do
    attempt = {
      "runner" => "runner:99",
      "error_type" => "error",
      "error_message" => "ProviderModelNotFoundError\n data: {\n  providerID: \"deepseek-v4-pro\",\n  modelID: \"\",\n}"
    }
    failed_run([ attempt ])

    expect(described_class.call.findings.first[:model]).to eq("deepseek-v4-pro")
  end

  it "groups repeated failures of the same runner/model and counts occurrences" do
    2.times { failed_run([ model_not_found_attempt(runner: "runner:99", model: "moonshotai/kimi-k2") ]) }

    findings = described_class.call.findings

    expect(findings.size).to eq(1)
    expect(findings.first[:occurrences]).to eq(2)
    expect(findings.first[:run_ids].size).to eq(2)
  end

  it "enriches findings with the runner name and key when the runner exists" do
    runner = create(:runner, name: "Configured Runner")
    failed_run([ model_not_found_attempt(runner: "runner:#{runner.id}", model: "moonshotai/kimi-k2") ])

    finding = described_class.call.findings.first

    expect(finding[:runner_name]).to eq("Configured Runner")
    expect(finding[:runner_key]).to eq(runner.runner_key)
  end

  it "scopes its scan to AgentRun, so tenant RLS isolates it per account when called under a context" do
    # Tenant isolation itself is proven against the DB policy in
    # spec/security/tenant_context_spec.rb ("filters project-owned records").
    # Here we just pin that the detector reads through the RLS-scoped relation.
    failed_run([ model_not_found_attempt(runner: "runner:2", model: "ours/model") ])

    relation = instance_double(ActiveRecord::Relation)
    allow(AgentRun).to receive(:where).and_return(relation)
    allow(relation).to receive_messages(where: relation, order: relation, limit: relation, select: [])

    described_class.call

    expect(AgentRun).to have_received(:where).with(status: AgentRun::TERMINAL_FAILURE_STATUSES)
  end

  it "ignores non-model errors and runs outside the lookback window" do
    failed_run([ { "runner" => "claude", "error_type" => "rate_limited", "error_message" => "Rate limited" } ])
    failed_run([ model_not_found_attempt(runner: "runner:99", model: "old/model") ], updated_at: 10.days.ago)

    expect(described_class.call(since: 2.days.ago).findings).to be_empty
  end
end
