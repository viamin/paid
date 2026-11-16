# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteMaintenanceRunActivity do
  let(:project) { create(:project) }
  let(:run) do
    create(:agent_run, goal: "maintenance", status: "running", issue: nil,
      custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A",
      maintenance_scope_kind: "named", maintenance_scope: "app/workflows/a.rb")
  end

  # @spec MAINT-020
  it "completes a report-only run successfully with no findings" do
    run.log!("stdout", "No unnecessary code found in the requested scope.")

    result = described_class.new.execute(agent_run_id: run.id)

    expect(result).to include(agent_run_id: run.id, success: true)
    expect(run.reload.status).to eq("completed")
    expect(run.pull_request_url).to be_nil
  end

  it "is idempotent for an already-finished run" do
    run.update!(status: "cancelled", completed_at: Time.current)

    result = described_class.new.execute(agent_run_id: run.id)

    expect(result[:agent_run_id]).to eq(run.id)
    expect(run.reload.status).to eq("cancelled")
  end

  it "preserves the collected report evidence in the run logs" do
    run.log!("stdout", "Finding: workflow A duplicates workflow B helpers.")

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.agent_run_logs.stdout.count).to eq(1)
  end

  # @spec MAINT-020
  it "fails when the agent modified source files" do
    result = described_class.new.execute(agent_run_id: run.id, has_changes: true)

    expect(result).to include(agent_run_id: run.id, success: false)
    expect(run.reload).to have_attributes(status: "failed", error_message: a_string_including("report-only"))
  end
end
