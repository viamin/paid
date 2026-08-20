# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260820001000_expand_egress_allowlist_entries_for_audit_and_ui")

RSpec.describe ExpandEgressAllowlistEntriesForAuditAndUi, :no_db do
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive_messages(
      column_exists?: false,
      index_exists?: false,
      add_column: nil,
      add_index: nil,
      remove_check_constraint: nil
    )
  end

  it "adds audit columns and indexes without dropping existing safety constraints" do
    migration.up

    expect(migration).to have_received(:add_column).with(
      :egress_allowlist_entries,
      :source_kind,
      :string,
      limit: 20,
      default: "tenant",
      null: false,
      comment: "Origin of the entry (tenant, platform, operator_override) for provenance rendering on agent runs."
    )
    expect(migration).to have_received(:add_column).with(
      :egress_allowlist_entries,
      :disabled_at,
      :datetime
    )
    expect(migration).not_to have_received(:remove_check_constraint)
  end
end
