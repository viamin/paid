# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117050838_enforce_partial_closeout_projection_tenancy")

RSpec.describe PartialCloseoutProjection, :tenant_isolation do
  # Until #5133 restores policy serialization, schema-loaded test databases
  # need the migration's policies. This verifies the migrated boundary;
  # unmodified-bootstrap acceptance remains a separate explicit gate.
  before do
    connection = ActiveRecord::Base.connection
    EnforcePartialCloseoutProjectionTenancy::TABLES.each do |table|
      next if connection.select_value("SELECT 1 FROM pg_policies WHERE tablename = '#{table}' AND policyname = 'tenant_isolation'")

      ActiveRecord::Migration.suppress_messages { EnforcePartialCloseoutProjectionTenancy.new.send(:enable_policy, table) }
    end
  end

  let(:account) { create(:account) }

  def seed_projection(project)
    issue = create(:issue, project:)
    checkpoint = described_class.create!(project:, computed_at: Time.current, generation: SecureRandom.uuid)
    entry = PartialCloseoutProjectionEntry.create!(project:, issue:, evidence_digest: "a" * 64,
      projection_generation: checkpoint.generation)
    [ checkpoint, entry ]
  end

  # @spec POSTGRESQL-PERSISTENCE-006 PARTIAL-CLOSEOUT-042
  it "hides other tenants' checkpoints and display rows without hiding intentional system reads" do
    mine, other = TenantContext.with_system_access do
      [ seed_projection(create(:project, account:)), seed_projection(create(:project)) ]
    end
    TenantContext.with(account) do
      expect(described_class.all).to contain_exactly(mine.first)
      expect(PartialCloseoutProjectionEntry.all).to contain_exactly(mine.last)
    end
    TenantContext.with(nil) do
      expect(described_class.count).to eq(0)
      expect(PartialCloseoutProjectionEntry.count).to eq(0)
    end
    TenantContext.with_system_access do
      expect(described_class.all).to contain_exactly(mine.first, other.first)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006
  it "rejects creating another tenant's checkpoint" do
    foreign_project = TenantContext.with_system_access { create(:project) }
    TenantContext.with(account) do
      expect do
        described_class.transaction(requires_new: true) { described_class.create!(project: foreign_project) }
      end.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006
  it "rejects entry links to a different project even inside intentional system access" do
    TenantContext.with_system_access do
      _checkpoint, entry = seed_projection(create(:project, account:))
      foreign_issue = create(:issue, project: create(:project, account:))
      expect do
        PartialCloseoutProjectionEntry.transaction(requires_new: true) { entry.update_columns(issue_id: foreign_issue.id) }
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
