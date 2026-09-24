# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ModelRecovery do
  let(:user) { create(:user) }
  let(:project) { create(:project, created_by: user, account: user.account) }
  let!(:old_model) { create(:llm_model, :openai, model_id: "old-model", tier: "mid") }
  let!(:replacement) { create(:llm_model, :openai, model_id: "working-model", tier: "high") }
  let(:runner) { create(:runner, user: user, runner_key: "codex", tier_model_ids: { "mid" => old_model.model_id }) }
  let(:run) { create(:agent_run, project: project, runner: runner, agent_type: "codex") }
  let(:executor) { instance_double(AgentHarness::CommandExecutor) }
  let(:discovered) { [ { id: replacement.model_id, isDefault: true } ] }
  let(:smoke_result) do
    AgentHarness::CommandExecutor::Result.new(stdout: [
      { type: "item.completed", item: { type: "agent_message", text: "OK" } },
      { type: "turn.completed", usage: { input_tokens: 1, output_tokens: 1 } }
    ].map(&:to_json).join("\n"), stderr: "", exit_code: 0, duration: 0.1)
  end

  before do
    allow(executor).to receive(:execute) do |command, **|
      if command.first == "node"
        AgentHarness::CommandExecutor::Result.new(stdout: { id: 2, result: { data: discovered } }.to_json,
          stderr: "", exit_code: 0, duration: 0.1)
      else
        smoke_result
      end
    end
  end

  def recovery
    described_class.new(agent_run: run, runner: runner, tier: "mid", executor: executor)
  end

  # @spec RUNNER-FALLBACK-007, RUNNER-FALLBACK-008
  it "verifies a cross-tier replacement and reuses it after reload and catalog refresh" do
    result = recovery.call(rejected_model_id: old_model.model_id)
    expect(result).to be_success
    expect(result.model_id).to eq(replacement.model_id)
    expect(executor).to have_received(:execute).with(array_including("exec", "--model", replacement.model_id),
      hash_including(env: hash_including("OPENAI_API_KEY" => nil, "OPENAI_BASE_URL" => nil)))
    expect(runner.reload.auth_type).to eq("subscription")
    replacement.update!(active: false)

    resolved = Runners::ResolveTierModel.call(runner: runner.reload, user: user, tier: "mid", project: project)
    expect(resolved).to have_attributes(model_id: replacement.model_id, source: "verified_recovery")
    expect(run.agent_run_logs.where("metadata ->> 'type' = ?", "model_auth_recovery")).to exist
  end

  # @spec RUNNER-FALLBACK-008
  it "recovers again when the verified model is rejected later" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    replacement.update!(model_id: "next-working-model")
    discovered.replace([ { id: replacement.model_id, isDefault: true } ])
    expect(recovery.call(rejected_model_id: "working-model")).to be_success
    result = Runners::ResolveTierModel.call(runner: runner.reload, user: user, tier: "mid", project: project)
    expect(result.model_id).to eq("next-working-model")
  end

  # @spec RUNNER-FALLBACK-009
  context "when replacement execution fails" do
    let(:smoke_result) { AgentHarness::CommandExecutor::Result.new(stdout: "", stderr: "Network unavailable", exit_code: 1, duration: 0.1) }

    it "does not remember an unverified replacement" do
      expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
      expect(Runners::VerifiedModels.new(runner.reload).model_for("mid", project: project)).to be_nil
    end
  end

  # @spec RUNNER-FALLBACK-007
  it "preserves an explicit project model requirement" do
    project.update!(model_preferences: { "required_model_id" => old_model.model_id })
    expect(executor).not_to receive(:execute).with(array_including("exec"), any_args)
    expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
  end

  # @spec RUNNER-FALLBACK-007
  it "never tries a project-excluded or operator-disabled alternative" do
    project.update!(model_preferences: { "excluded_model_ids" => [ replacement.model_id ] })
    expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
    project.update!(model_preferences: {})
    replacement.operator_disable!
    expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
  end

  # @spec RUNNER-FALLBACK-008
  it "does not reuse a learned choice after explicit runner configuration changes" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    runner.update!(tier_model_ids: { "mid" => replacement.model_id })
    expect(Runners::VerifiedModels.new(runner.reload).model_for("mid", project: project)).to be_nil
  end

  # @spec RUNNER-FALLBACK-008
  it "checks project restrictions again before reusing a learned choice" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    project.update!(model_preferences: { "excluded_model_ids" => [ replacement.model_id ] })
    expect(Runners::VerifiedModels.new(runner.reload).model_for("mid", project: project)).to be_nil
  end

  # @spec RUNNER-FALLBACK-008
  it "does not overwrite a concurrent manual configuration change" do
    # Replace the external execution response with a callback that edits the
    # persisted configuration while verification is in flight.
    allow(executor).to receive(:execute).with(array_including("exec"), any_args) do
      Runner.find(runner.id).update!(tier_model_ids: { "mid" => replacement.model_id })
      smoke_result
    end
    expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
    expect(Runners::VerifiedModels.new(runner.reload).model_for("mid", project: project)).to be_nil
  end

  # @spec RUNNER-FALLBACK-007, RUNNER-FALLBACK-009
  it "bounds repeated model rejections across calls on the same recovery session" do
    allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "selector unavailable")
    discovered.replace([ replacement.model_id, "alternative-2", "alternative-3", "alternative-4" ].map { |id| { id: id } })
    allow(executor).to receive(:execute).with(array_including("exec"), any_args) do |command, **|
      model = command[command.index("--model") + 1]
      error = "The '#{model}' model is not supported when using Codex with a ChatGPT account."
      AgentHarness::CommandExecutor::Result.new(stdout: { type: "error", message: error }.to_json,
        stderr: "", exit_code: 1, duration: 0.1)
    end
    session = recovery
    2.times { expect(session.call(rejected_model_id: old_model.model_id)).not_to be_success }
    expect(executor).to have_received(:execute).with(array_including("exec"), any_args).exactly(3).times
    expect(Runners::VerifiedModels.new(runner.reload).model_for("mid", project: project)).to be_nil
  end

  # @spec RUNNER-FALLBACK-007
  it "does not start discovery after the run execution deadline" do
    expect(executor).not_to receive(:execute)
    session = described_class.new(agent_run: run, runner: runner, tier: "mid", executor: executor, deadline: 1.second.ago)
    expect(session.call(rejected_model_id: old_model.model_id)).not_to be_success
  end

  # @spec RUNNER-FALLBACK-008
  it "does not let an older successful preflight overwrite a newer recovery" do
    evidence = Runners::VerifiedModels.new(runner)
    older = evidence.reject!(old_model.model_id)
    newer = Runners::VerifiedModels.new(runner.reload).reject!("another-rejected-model")
    expect(evidence.remember!(tier: "mid", model_id: replacement.model_id, generation: older)).to be(false)
    expect(evidence.remember!(tier: "mid", model_id: replacement.model_id, generation: newer)).to be(true)
  end

  # @spec RUNNER-FALLBACK-008
  it "uses the verified model in the next run's command without rediscovery" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    later_run = create(:agent_run, project: project, runner: runner.reload, agent_type: "codex")
    create(:model_selection, agent_run: later_run, llm_model: old_model, tier: "mid")
    activity = Activities::RunAgentActivity.new
    context = Activities::RunAgentActivity::CommandContext.new(runner_candidate: runner.routing_key, runner: "codex", user: user)
    command = activity.send(:build_command, context, "test task", agent_run: later_run)
    expect(command.join(" ")).to include("--model working-model")
    expect(executor).to have_received(:execute).with(array_including("node"), any_args).once
  end

  # @spec RUNNER-FALLBACK-008
  it "does not share learned models with another runner or auth type" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    api_key = create(:runner_api_key, user: user, api_service_type: "openai")
    api_runner = create(:runner, :api_key, user: user, runner_key: "codex", provider_api_key: api_key,
      tier_model_ids: { "mid" => old_model.model_id })
    expect(Runners::VerifiedModels.new(api_runner).model_for("mid", project: project)).to be_nil
  end

  # @spec RUNNER-FALLBACK-007
  it "preserves explicit maximum tier restrictions during cross-tier recovery" do
    project.update!(model_preferences: { "max_tier" => "mid" })
    expect(recovery.call(rejected_model_id: old_model.model_id)).not_to be_success
    expect(executor).not_to have_received(:execute).with(array_including("exec"), any_args)
  end

  # @spec RUNNER-FALLBACK-009
  it "preserves rate-limit state instead of shadowing it with a recovery state row" do
    state = user.runner_states.create!(runner_name: runner.state_key, rate_limited_until: 1.hour.from_now)
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    expect(state.reload).to be_rate_limited
    expect(user.runner_states.where(runner_name: runner.routing_key)).not_to exist
  end

  # @spec MODEL-SELECTION-005, RUNNER-FALLBACK-008
  it "uses runner-local evidence during model selection after global catalog deactivation" do
    expect(recovery.call(rejected_model_id: old_model.model_id)).to be_success
    replacement.update!(active: false)
    later_run = create(:agent_run, project: project, runner: runner.reload, agent_type: "codex")
    later_run.issue.update!(body: "Detailed requirements " * 40)
    selected = Models::MetaAgentSelector.new(agent_run: later_run).call
    expect(selected.fetch(:model).model_id).to eq(replacement.model_id)
  end
end
