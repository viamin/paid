# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PauseExpansion do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "records a pause with the posture it returns the project from" do
    pause = described_class.call(
      project:, reason: "material_reversal", detail: "A settled decision was reversed by delegated work."
    )

    expect(pause).to be_persisted
    expect(pause.reason).to eq("material_reversal")
    expect(pause.posture_before).to eq("conservative")
    expect(ProjectDelegation::ExpansionGuard).to be_paused(project)
    expect(ProjectDelegation::ExpansionGuard.effective_posture(project)).to eq("conservative")
  end

  it "routes one focused blocking Inbox decision for human review" do
    pause = described_class.call(
      project:, reason: "security_breach", detail: "Container egress breached the tenant boundary."
    )

    notification = Notification.find_by(account:, source: "project_delegation_expansion_pause", subject: project)
    expect(notification).to be_blocking
    expect(notification).to be_error
    expect(notification.active?).to be(true)
    expect(notification.resolved_project).to eq(project)
    expect(notification.metadata).to include(
      "reason" => "security_breach",
      "pause_id" => pause.id,
      "recommended_action" => a_string_including("conservative")
    )
  end

  it "keeps a repeated equivalent pause in the same focused decision" do
    described_class.call(project:, reason: "missing_evidence", detail: "Pilot metrics could not be produced.")
    described_class.call(project:, reason: "missing_evidence", detail: "Pilot metrics could not be produced.")

    notifications = Notification.where(account:, source: "project_delegation_expansion_pause", subject: project)
    expect(notifications.count).to eq(1)
  end

  it "blocks broadening even when every pilot threshold is met" do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)

    described_class.call(project:, reason: "trust_breach", detail: "Untrusted content reached a trusted boundary.")

    result = ProjectDelegation::ExpansionGuard.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to include(:expansion_paused)
  end

  it "records an audit event for the pause" do
    actor = create(:user, :member, account:)
    pause = described_class.call(
      project:, reason: "tenant_breach", detail: "Cross-tenant read attempted.", actor:
    )

    event = account.account_activity_events.by_action("project_delegation.expansion_paused").last
    expect(event).to have_attributes(actor:, subject: pause)
  end

  it "rejects an unknown pause reason with a typed error" do
    expect { described_class.call(project:, reason: "whim", detail: "nope") }
      .to raise_error(ProjectDelegation::PauseExpansion::InvalidPauseReason)
  end
end
