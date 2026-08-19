# frozen_string_literal: true

require "rails_helper"

# @spec EXECUTION-AUDIT-003
RSpec.describe ExecutionAuditEventRetentionJob do
  it "deletes events older than the retention period" do
    old_event = create(:execution_audit_event, created_at: 401.days.ago)
    new_event = create(:execution_audit_event, created_at: 10.days.ago)

    described_class.perform_now

    expect(ExecutionAuditEvent.find_by(id: old_event.id)).to be_nil
    expect(ExecutionAuditEvent.find_by(id: new_event.id)).to be_present
  end

  it "accepts a custom retention period" do
    old_event = create(:execution_audit_event, created_at: 100.days.ago)
    new_event = create(:execution_audit_event, created_at: 10.days.ago)

    described_class.perform_now(retention_period: 30.days)

    expect(ExecutionAuditEvent.find_by(id: old_event.id)).to be_nil
    expect(ExecutionAuditEvent.find_by(id: new_event.id)).to be_present
  end

  it "returns deleted count" do
    result = described_class.perform_now

    expect(result).to be_a(Integer)
    expect(result).to be >= 0
  end

  it "does not delete recent events" do
    recent_event = create(:execution_audit_event, created_at: 1.day.ago)

    described_class.perform_now

    expect(ExecutionAuditEvent.find_by(id: recent_event.id)).to be_present
  end
end
