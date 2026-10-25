# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutions::Cancel do # @spec PREREQ-EXEC-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:validation) { create(:prerequisite_execution_validation, :running, project: project, issue: issue) }
  let(:run) { validation.agent_run }

  before do
    run.update!(container_id: "run-9")
    allow(validation).to receive(:agent_run).and_return(run)
    allow(run).to receive(:cleanup_execution_environment) { run.update_columns(container_id: nil) }
    allow(Containers::McpProvisioner).to receive(:new).and_return(instance_double(Containers::McpProvisioner,
      cleanup_tool_sidecars: nil))
  end

  it "cancels the attempt, preserves collected steps, cleans up, and cancels the paired run" do
    validation.update!(steps: [ { "key" => "checkout_identity", "status" => "succeeded", "commit" => "abc" } ])

    result = described_class.call(validation)

    expect(result.outcome).to eq(:cancelled)
    expect(validation.reload).to be_cancelled
    expect(validation.finished_at).to be_present
    expect(validation.steps).to be_present
    expect(validation.evidence["cleanup"]["run_container"]).to eq("cleaned")
    expect(run.reload.status).to eq("cancelled")
  end

  it "refuses to cancel a terminal attempt" do
    validation.update!(status: "succeeded", finished_at: Time.current)

    result = described_class.call(validation.reload)

    expect(result.outcome).to eq(:already_terminal)
    expect(validation.reload.status).to eq("succeeded")
  end
end
