# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::BindRunner do
  describe ".call" do
    let(:project) { create(:project) }
    let(:owner) { project.created_by }
    let(:run) { create(:agent_run, :queued, project: project) }

    before do
      allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ runner.id, resolved_agent_type ])
    end

    context "when the resolved agent type is valid" do
      let(:runner) { create(:runner, runner_key: "codex", user: owner) }
      let(:resolved_agent_type) { "codex" }

      it "persists the resolved runner and agent_type through validation" do
        result = described_class.call(agent_run: run)

        expect(result).to eq(runner)
        run.reload
        expect(run.runner_id).to eq(runner.id)
        expect(run.agent_type).to eq("codex")
        expect(run).to be_valid
      end

      # @spec EXECUTION-AUDIT-004
      it "records the runner selection in the execution audit trail" do
        described_class.call(agent_run: run)

        event = ExecutionAuditEvent.for_agent_run(run).by_event_name("execution.runner_selected").last
        expect(event).to have_attributes(
          runner_key: "codex",
          actor_type: "system",
          actor_id: "agent_runs.bind_runner"
        )
        expect(event.metadata).to include(
          "resolved_runner_id" => runner.id,
          "resolved_agent_type" => "codex"
        )
      end
    end

    context "when the resolved agent type is invalid" do
      let(:runner) { create(:runner, runner_key: "codex", user: owner) }
      let(:resolved_agent_type) { "bogus_invalid_type" }

      it "returns nil instead of persisting an unclaimable agent_type" do
        result = described_class.call(agent_run: run)

        expect(result).to be_nil
        run.reload
        expect(run.runner_id).to be_nil
        expect(run.agent_type).to eq("claude_code")
      end

      it "logs the invalid resolution" do
        expect(Rails.logger).to receive(:error).with(
          hash_including(message: "bind_runner.invalid_resolution")
        )
        described_class.call(agent_run: run)
      end
    end

    context "when the run already has a pinned runner" do
      let(:runner) { create(:runner, runner_key: "codex", user: owner) }
      let(:resolved_agent_type) { "codex" }

      it "returns nil without invoking the resolver" do
        run.update!(runner_id: runner.id, agent_type: "codex")

        expect(AgentRuns::RunnerResolver).not_to receive(:call)

        expect(described_class.call(agent_run: run)).to be_nil
      end
    end
  end
end
