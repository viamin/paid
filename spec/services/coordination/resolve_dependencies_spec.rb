# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::ResolveDependencies do
  let(:workflow_id) { "dep-workflow-#{SecureRandom.hex(4)}" }
  let(:project) { create(:project) }
  let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
  let(:run_b) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
  let(:dependent_run) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

  describe ".call" do
    it "returns ready when all dependencies are met" do
      create(:agent_coordination_signal, :dependency_completed,
        source_agent_run: run_a, parent_workflow_id: workflow_id)
      create(:agent_coordination_signal, :dependency_completed,
        source_agent_run: run_b, parent_workflow_id: workflow_id)

      result = described_class.call(
        agent_run: dependent_run,
        required_run_ids: [ run_a.id, run_b.id ]
      )

      expect(result).to be_ready
      expect(result).not_to be_failed
    end

    it "returns not ready when some dependencies are missing" do
      create(:agent_coordination_signal, :dependency_completed,
        source_agent_run: run_a, parent_workflow_id: workflow_id)

      result = described_class.call(
        agent_run: dependent_run,
        required_run_ids: [ run_a.id, run_b.id ]
      )

      expect(result).not_to be_ready
      expect(result).not_to be_failed
    end

    it "returns failed when a dependency has failed" do
      create(:agent_coordination_signal, :dependency_failed,
        source_agent_run: run_a, parent_workflow_id: workflow_id)

      result = described_class.call(
        agent_run: dependent_run,
        required_run_ids: [ run_a.id ]
      )

      expect(result).not_to be_ready
      expect(result).to be_failed
      expect(result.failed_run_ids).to include(run_a.id)
    end

    it "returns ready for empty required_run_ids" do
      result = described_class.call(
        agent_run: dependent_run,
        required_run_ids: []
      )

      expect(result).to be_ready
    end

    it "returns not ready when agent run has no parent_workflow_id" do
      run = create(:agent_run, project: project, parent_workflow_id: nil)

      result = described_class.call(
        agent_run: run,
        required_run_ids: [ run_a.id ]
      )

      expect(result).not_to be_ready
      expect(result.error).to include("no parent_workflow_id")
    end
  end
end
