# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PauseExpansion do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:enrollment) { create(:delegation_pilot_enrollment, project:) }
  let(:actor) { create(:user, :owner, account:) }

  def pause(reason:, evidence: {})
    described_class.call(enrollment:, reason:, evidence:, actor:)
  end

  it "pauses a material reversal and routes it for human review" do
    result = pause(reason: :material_reversal,
      evidence: { "snapshot_id" => 42, "issue_id" => 7 })

    expect(result).to be_paused
    expect(enrollment.reload).to be_paused
    expect(enrollment.pause_reason).to eq("material_reversal")
    expect(enrollment.paused_at).to be_within(1.second).of(Time.current)
    expect(enrollment.pause_evidence).to include("issue_id" => 7)

    event = account.account_activity_events.by_action("delegation_pilot.paused").last
    expect(event).to have_attributes(actor:, subject: enrollment)
    expect(event.metadata).to include("reason" => "material_reversal")

    notification = Notification.find_by(source: described_class::NOTIFICATION_SOURCE)
    expect(notification).to be_blocking
    expect(notification.subject).to eq(project)
    expect(notification.metadata).to include("reason" => "material_reversal", "enrollment_id" => enrollment.id)
  end

  it "pauses a security/tenant/trust breach" do
    pause(reason: :security_tenant_trust_breach, evidence: { "incident_id" => "SEC-9" })

    expect(enrollment.reload.pause_reason).to eq("security_tenant_trust_breach")
    expect(Notification.find_by(source: described_class::NOTIFICATION_SOURCE).metadata)
      .to include("reason" => "security_tenant_trust_breach")
  end

  it "pauses missing metric evidence" do
    pause(reason: :missing_evidence)

    expect(enrollment.reload.pause_reason).to eq("missing_evidence")
  end

  it "is idempotent for a repeated pause with the same reason" do
    2.times { pause(reason: :missing_evidence) }

    expect(account.account_activity_events.by_action("delegation_pilot.paused").count).to eq(1)
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(1)
  end

  it "records the newest reason when a later condition pauses again" do
    pause(reason: :missing_evidence)
    pause(reason: :material_reversal, evidence: { "issue_id" => 7 })

    expect(enrollment.reload.pause_reason).to eq("material_reversal")
    notification = Notification.find_by(source: described_class::NOTIFICATION_SOURCE)
    expect(notification.metadata).to include("reason" => "material_reversal")
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(1)
  end

  it "rejects an unknown pause reason" do
    expect { pause(reason: :vibes) }.to raise_error(ArgumentError, /vibes/)
    expect(enrollment.reload).to be_active
  end

  it "preserves recorded metric evidence when pausing" do
    create(:delegation_pilot_metric_snapshot, enrollment:, project:, posture: "bounded_delivery")

    pause(reason: :missing_evidence)

    expect(enrollment.reload.snapshots.count).to eq(1)
  end
end
