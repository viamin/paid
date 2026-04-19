# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::SendSignal do
  let(:workflow_id) { "test-workflow-#{SecureRandom.hex(4)}" }
  let(:project) { create(:project) }
  let(:source_run) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

  describe ".call" do
    it "creates a broadcast signal when no target is specified" do
      result = described_class.call(
        source_agent_run: source_run,
        signal_type: "files_changed",
        payload: { files: [ "app/models/user.rb" ] }
      )

      expect(result).to be_success
      expect(result.signal).to be_persisted
      expect(result.signal.signal_type).to eq("files_changed")
      expect(result.signal.target_agent_run_id).to be_nil
      expect(result.signal.parent_workflow_id).to eq(workflow_id)
    end

    it "creates a targeted signal when target is specified" do
      target_run = create(:agent_run, project: project, parent_workflow_id: workflow_id)

      result = described_class.call(
        source_agent_run: source_run,
        signal_type: "sequencing_hint",
        payload: { hint: "run migrations first" },
        target_agent_run: target_run
      )

      expect(result).to be_success
      expect(result.signal.target_agent_run_id).to eq(target_run.id)
    end

    it "fails when source run has no parent_workflow_id" do
      run = create(:agent_run, project: project, parent_workflow_id: nil)

      result = described_class.call(
        source_agent_run: run,
        signal_type: "dependency_completed"
      )

      expect(result).not_to be_success
      expect(result.error).to include("no parent_workflow_id")
    end

    it "fails for invalid signal_type" do
      result = described_class.call(
        source_agent_run: source_run,
        signal_type: "invalid_type"
      )

      expect(result).not_to be_success
      expect(result.error).to include("Signal type")
    end
  end
end
