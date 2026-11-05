# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-005 @spec BOUNDED-PHASE-AUTHORIZATION-009
RSpec.describe Automation::DelegationRollback do
  let(:project) { create(:project, delegation_posture: "bounded_delivery", delegation_posture_revision: 2) }
  let(:run) { create(:agent_run, project:, admission_snapshot: { "evidence_revision" => "e1" }) }

  it "rolls back to conservative and holds admitted work without erasing evidence" do
    run
    result = described_class.call(project:, reason: "pilot evidence became stale")

    expect(result).to include(posture: "conservative", posture_revision: 3, held_runs: 1)
    expect(project.reload.delegation_posture).to eq("conservative")
    expect(run.reload).to have_attributes(admission_state: "held", admission_hold_reason: "pilot evidence became stale")
    expect(run.admission_snapshot).to eq("evidence_revision" => "e1")
    expect(project.account.account_activity_events.by_action("delegation.rolled_back")).to exist
  end

  it "does not transition an admission twice" do
    run
    described_class.call(project:, reason: "first")

    expect(Automation::AdmissionLifecycle.call(agent_run: run, transition: :revoke, reason: "second")).to be(false)
    expect(run.reload.admission_state).to eq("held")
  end
end
