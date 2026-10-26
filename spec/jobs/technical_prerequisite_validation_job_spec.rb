# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisiteValidationJob do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :queued, project:, base_commit_sha: "a" * 40, synthetic: true,
      external_metadata: {
        "technical_prerequisite_validation" => {
          "requirement_id" => 1, "requirement_name" => "audit", "command" => "bin/audit", "source_run_id" => 1
        }
      })
  end

  def validation_result(status, evidence = {})
    TechnicalPrerequisites::ValidateExecution::Result.new(status:, evidence:, setup_action: nil)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "uses a bounded low-priority worker for isolated network and container execution" do
    expect(described_class.queue_name).to eq("low_priority")
    expect(described_class.perform_timeout).to eq(10.minutes.to_i)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "completes the run when the validation succeeds" do
    expect(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      expect(Current.account).to eq(project.account)
      validation_result("completed")
    end

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("completed")
    expect(agent_run.completed_at).to be_present
    expect(agent_run.error_message).to be_nil
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "marks the run failed with the recorded validation error" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("failed", { "error" => "analyzer exited 3" }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("failed")
    expect(agent_run.error_message).to eq("analyzer exited 3")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not overwrite a run the operator cancelled while the validation ran" do
    agent_run.update!(status: "cancelled", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("completed"))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not re-execute a run that already reached a terminal state" do
    agent_run.update!(status: "failed", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records the failure and re-raises when the validation raises" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_raise(Containers::Provision::Error, "no container provisioned")

    expect { described_class.perform_now(agent_run.id) }.to raise_error(Containers::Provision::Error)

    expect(agent_run.reload.status).to eq("failed")
    expect(agent_run.error_message).to eq("no container provisioned")
  end
end
