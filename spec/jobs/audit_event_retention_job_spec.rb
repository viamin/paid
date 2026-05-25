# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditEventRetentionJob do
  let(:account) { create(:account) }

  it "deletes events older than the retention period" do
    old_event = account.account_activity_events.create!(
      action: "project.created",
      created_at: 400.days.ago,
      updated_at: 400.days.ago
    )
    new_event = account.account_activity_events.create!(
      action: "project.updated",
      created_at: 10.days.ago,
      updated_at: 10.days.ago
    )

    described_class.perform_now

    expect(AccountActivityEvent.find_by(id: old_event.id)).to be_nil
    expect(AccountActivityEvent.find_by(id: new_event.id)).to be_present
  end

  it "accepts a custom retention period" do
    old_event = account.account_activity_events.create!(
      action: "project.created",
      created_at: 100.days.ago,
      updated_at: 100.days.ago
    )
    new_event = account.account_activity_events.create!(
      action: "project.updated",
      created_at: 10.days.ago,
      updated_at: 10.days.ago
    )

    described_class.perform_now(retention_period: 30.days)

    expect(AccountActivityEvent.find_by(id: old_event.id)).to be_nil
    expect(AccountActivityEvent.find_by(id: new_event.id)).to be_present
  end

  it "returns deleted count" do
    result = described_class.perform_now

    expect(result).to be_a(Integer)
    expect(result).to be >= 0
  end

  it "does not delete recent events" do
    recent_event = account.account_activity_events.create!(
      action: "project.created",
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )

    described_class.perform_now

    expect(AccountActivityEvent.find_by(id: recent_event.id)).to be_present
  end
end
