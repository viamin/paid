# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260925005504_add_reopen_audit_to_issues")

RSpec.describe AddReopenAuditToIssues, :no_db do
  it "removes the reopen audit schema on rollback" do # @spec ISSUE-REOPEN-REVIEW-004
    migration = described_class.new
    allow(migration).to receive_messages(column_exists?: true, index_exists?: true)
    allow(migration).to receive(:remove_column)
    allow(migration).to receive(:remove_reference)
    allow(migration).to receive(:remove_index)

    migration.down

    expect(migration).to have_received(:remove_column).with(:issues, :reopened_at)
    expect(migration).to have_received(:remove_reference).with(:issues, :reopened_by, index: false)
    expect(migration).to have_received(:remove_index)
      .with(:issues, :reopened_by_id, algorithm: :concurrently)
    expect(migration).to have_received(:remove_column).with(:issues, :reopen_reason)
  end
end
