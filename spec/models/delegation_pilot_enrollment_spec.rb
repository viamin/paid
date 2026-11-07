# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe DelegationPilotEnrollment do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "enrolls a project with the bounded_delivery posture by default" do
    enrollment = create(:delegation_pilot_enrollment, project:)

    expect(enrollment).to be_active
    expect(enrollment.posture).to eq("bounded_delivery")
  end

  it "rejects unknown postures and statuses" do
    enrollment = build(:delegation_pilot_enrollment, project:, posture: "full_send")

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:posture]).to include(/not included/)

    enrollment = build(:delegation_pilot_enrollment, project:, status: "dormant")

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:status]).to include(/not included/)
  end

  it "requires a pause reason exactly when paused" do
    enrollment = build(:delegation_pilot_enrollment, project:, status: "paused")

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:pause_reason]).to include(/must be present/)

    enrollment = build(:delegation_pilot_enrollment, project:, pause_reason: "missing_evidence")

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:pause_reason]).to include(/must be blank/)

    expect(build(:delegation_pilot_enrollment, project:, status: "paused",
      pause_reason: "missing_evidence")).to be_valid
  end

  it "rejects unknown pause reasons" do
    enrollment = build(:delegation_pilot_enrollment, project:, status: "paused", pause_reason: "vibes")

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:pause_reason]).to include(/not included/)
  end

  it "keeps one enrollment per project" do
    create(:delegation_pilot_enrollment, project:)

    expect(build(:delegation_pilot_enrollment, project:)).not_to be_valid
  end

  it "requires the enrollment to stay inside the project's account" do
    other_account = create(:account)
    enrollment = build(:delegation_pilot_enrollment, project:, account: other_account)

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:account]).to include(/must match the project/)
  end

  it "exposes the latest snapshot per posture" do
    enrollment = create(:delegation_pilot_enrollment, project:)
    create(:delegation_pilot_metric_snapshot, enrollment:, project:, posture: "bounded_delivery",
      window_ended_at: 2.days.ago)
    latest = create(:delegation_pilot_metric_snapshot, enrollment:, project:, posture: "bounded_delivery",
      window_ended_at: 1.day.ago)

    expect(enrollment.latest_snapshot("bounded_delivery")).to eq(latest)
    expect(enrollment.latest_snapshot("conservative_baseline")).to be_nil
  end
end
