# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261123000000_secure_conflict_repair_scope_evidences")

RSpec.describe SecureConflictRepairScopeEvidences do
  let(:migration) { described_class.new }

  # @spec POSTGRESQL-PERSISTENCE-001
  it "keeps the RLS installer available to tenant-policy setup" do
    expect(migration).to respond_to(:enable_tenant_rls)
  end

  # @spec AUTO-MERGE-011
  it "refuses rollback before changing RLS or indexes when status-distinct evidence would lose history" do
    allow(migration).to receive(:disable_tenant_rls)
    allow(migration).to receive(:remove_index)

    expect { migration.down }.to raise_error(
      ActiveRecord::IrreversibleMigration,
      /prior unique index cannot represent losslessly/
    )
    expect(migration).not_to have_received(:disable_tenant_rls)
    expect(migration).not_to have_received(:remove_index)
  end
end
