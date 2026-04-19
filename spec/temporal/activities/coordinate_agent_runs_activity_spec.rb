# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CoordinateAgentRunsActivity do
  subject(:activity) { described_class.new }

  let(:workflow_id) { "coord-workflow-#{SecureRandom.hex(4)}" }
  let(:project) { create(:project) }

  describe "#execute" do
    it "raises for unknown operations" do
      expect {
        activity.execute(operation: "unknown")
      }.to raise_error(Temporalio::Error::ApplicationError, /Unknown coordination operation/)
    end

    context "with check_dependencies operation" do
      let(:run_a) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }
      let(:dependent_run) { create(:agent_run, project: project, parent_workflow_id: workflow_id) }

      it "returns ready when dependencies are met" do
        create(:agent_coordination_signal, :dependency_completed,
          source_agent_run: run_a, parent_workflow_id: workflow_id)

        result = activity.execute(
          operation: "check_dependencies",
          agent_run_id: dependent_run.id,
          required_run_ids: [ run_a.id ]
        )

        expect(result[:ready]).to be true
        expect(result[:failed]).to be false
      end

      it "returns not ready when dependencies are not met" do
        result = activity.execute(
          operation: "check_dependencies",
          agent_run_id: dependent_run.id,
          required_run_ids: [ run_a.id ]
        )

        expect(result[:ready]).to be false
      end
    end

    context "with notify_completion operation" do
      let(:run) { create(:agent_run, :completed, project: project, parent_workflow_id: workflow_id) }

      it "sends files_changed and dependency_completed signals" do
        result = activity.execute(
          operation: "notify_completion",
          agent_run_id: run.id,
          changed_files: [ "app/models/user.rb" ]
        )

        expect(result[:success]).to be true
        expect(result[:signals_sent]).to include("files_changed", "dependency_completed")
      end

      it "sends context_shared when context is provided" do
        result = activity.execute(
          operation: "notify_completion",
          agent_run_id: run.id,
          changed_files: [],
          context: { summary: "Added user model" }
        )

        expect(result[:success]).to be true
        expect(result[:signals_sent]).to include("dependency_completed", "context_shared")
      end

      it "skips files_changed when no files provided" do
        result = activity.execute(
          operation: "notify_completion",
          agent_run_id: run.id,
          changed_files: []
        )

        expect(result[:signals_sent]).not_to include("files_changed")
        expect(result[:signals_sent]).to include("dependency_completed")
      end
    end

    context "with propagate_failure operation" do
      let(:failed_run) do
        create(:agent_run, :failed, project: project, parent_workflow_id: workflow_id,
          error_message: "Execution failed")
      end

      it "sends failure signal" do
        result = activity.execute(
          operation: "propagate_failure",
          agent_run_id: failed_run.id
        )

        expect(result[:success]).to be true
      end

      it "cancels dependents when requested" do
        queued_run = create(:agent_run, :queued, project: project, parent_workflow_id: workflow_id)

        result = activity.execute(
          operation: "propagate_failure",
          agent_run_id: failed_run.id,
          cancel_dependents: true
        )

        expect(result[:success]).to be true
        expect(result[:cancelled_run_ids]).to include(queued_run.id)
      end
    end
  end
end
