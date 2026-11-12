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

  # @spec PARTIAL-CLOSEOUT-032
  it "uses a bounded low-priority worker for isolated network and container execution" do
    expect(described_class.queue_name).to eq("low_priority")
    expect(described_class.perform_timeout).to eq(20.minutes.to_i)
    expect(TechnicalPrerequisites::ValidateExecution::COMMAND_TIMEOUT).to eq(5.minutes)
  end

  # @spec PARTIAL-CLOSEOUT-032
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

  # @spec PARTIAL-CLOSEOUT-032
  it "executes a non-performance validation while the project scheduler is paused" do
    project.update!(scheduler_paused_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("completed"))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("completed")
    expect(TechnicalPrerequisites::ValidateExecution).to have_received(:call).with(
      agent_run:, native_command: "bin/audit"
    )
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "marks the run failed with the recorded validation error" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("failed", { "error" => "analyzer exited 3" }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("failed")
    expect(agent_run.error_message).to eq("analyzer exited 3")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "does not overwrite a run the operator cancelled while the validation ran" do
    agent_run.update!(status: "cancelled", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("completed"))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "does not re-execute a run that already reached a terminal state" do
    agent_run.update!(status: "failed", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records the failure and re-raises when the validation raises" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_raise(Containers::Provision::Error, "no container provisioned")

    expect { described_class.perform_now(agent_run.id) }.to raise_error(Containers::Provision::Error)

    expect(agent_run.reload.status).to eq("failed")
    expect(agent_run.error_message).to eq("no container provisioned")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "schedules the acceptance audit after a terminal performance measurement" do
    issue = create(:issue, project:)
    agent_run.update!(issue:, external_metadata: {
      "technical_prerequisite_validation" => {
        "requirement_id" => 1, "requirement_name" => "measure", "command" => "bin/measure", "source_run_id" => 1,
        "performance_measurement" => { "samples" => 2 }
      }
    })
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("completed"))
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("completed")
    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:)
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "schedules reassessment after terminal non-performance technical evidence" do
    issue = create(:issue, project:)
    agent_run.update!(issue:)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("failed", { "error" => "analyzer exited 3" }))
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.status).to eq("failed")
    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "fails a queued performance measurement when the project scheduler is paused before it starts" do
    issue = create(:issue, project:)
    agent_run.update!(issue:, external_metadata: {
      "technical_prerequisite_validation" => {
        "requirement_id" => 1, "requirement_name" => "measure", "command" => "bin/measure", "source_run_id" => 1,
        "performance_measurement" => { "samples" => 2 }
      }
    })
    project.update!(scheduler_paused_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload).to have_attributes(
      status: "failed", error_message: "Project scheduling is paused; resume it before running performance measurement."
    )
    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps the terminal measurement status when audit scheduling fails" do
    issue = create(:issue, project:)
    agent_run.update!(issue:, external_metadata: {
      "technical_prerequisite_validation" => {
        "requirement_id" => 1, "requirement_name" => "measure", "command" => "bin/measure", "source_run_id" => 1,
        "performance_measurement" => { "samples" => 2 }
      }
    })
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(validation_result("completed"))
    allow(PartialCloseouts::AutoAudit).to receive(:call)
      .and_raise(ActiveRecord::RecordNotUnique, "concurrent continuation request")

    expect { described_class.perform_now(agent_run.id) }.to raise_error(ActiveRecord::RecordNotUnique)

    expect(agent_run.reload.status).to eq("completed")
    expect(agent_run.completed_at).to be_present

    allow(PartialCloseouts::AutoAudit).to receive(:call).and_return(nil)
    described_class.perform_now(agent_run.id)

    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:).twice
    expect(TechnicalPrerequisites::ValidateExecution).to have_received(:call).once
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "does not hand a cancelled terminal measurement to the acceptance audit" do
    issue = create(:issue, project:)
    agent_run.update!(status: "cancelled", completed_at: Time.current, issue:, external_metadata: {
      "technical_prerequisite_validation" => {
        "requirement_id" => 1, "requirement_name" => "measure", "command" => "bin/measure", "source_run_id" => 1,
        "performance_measurement" => { "samples" => 2 }
      }
    })
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end
end
