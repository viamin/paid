# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ResumePilotEnrollment do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:enrollment) { create(:delegation_pilot_enrollment, :paused, project:) }
  let(:reviewer) { create(:user, :owner, account:) }

  it "restores an active pilot after human review and records the reviewer" do
    result = described_class.call(enrollment:, actor: reviewer)

    expect(result).to be_active
    expect(enrollment.reload).to be_active
    expect(enrollment.pause_reason).to be_nil
    expect(enrollment.paused_at).to be_nil
    expect(enrollment.pause_evidence).to eq({})

    event = account.account_activity_events.by_action("delegation_pilot.resumed").last
    expect(event).to have_attributes(actor: reviewer, subject: enrollment)
  end

  it "requires a reviewer" do
    expect {
      described_class.call(enrollment:, actor: nil)
    }.to raise_error(ArgumentError, /human review/)
  end

  it "leaves an already-active enrollment untouched" do
    enrollment.update!(status: "active", pause_reason: nil, paused_at: nil)

    expect(described_class.call(enrollment:, actor: reviewer)).to be_active
    expect(account.account_activity_events.by_action("delegation_pilot.resumed").count).to eq(0)
  end
end
