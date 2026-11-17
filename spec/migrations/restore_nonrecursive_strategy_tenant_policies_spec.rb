# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117161325_restore_nonrecursive_strategy_tenant_policies")

# DDL and deliberately invalid fixtures roll back inside each example.
RSpec.describe RestoreNonrecursiveStrategyTenantPolicies do
  let(:connection) { ActiveRecord::Base.connection }

  # @spec POSTGRESQL-PERSISTENCE-013
  it "refuses existing cross-strategy current references without changing records" do
    TenantContext.with_system_access do
      own, other, version = strategy_records
      connection.execute("ALTER TABLE strategies DISABLE TRIGGER validate_strategy_current_version_reference")
      own.update_columns(current_version_id: version.id)
      connection.execute("ALTER TABLE strategies ENABLE TRIGGER validate_strategy_current_version_reference")

      expect { repair }.to raise_error(ActiveRecord::MigrationError, /current: 1, parent: 0/)
      expect(own.reload.current_version_id).to eq(version.id)
      expect(version.reload.strategy_id).to eq(other.id)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "refuses existing cross-strategy parent references without changing records" do
    TenantContext.with_system_access do
      own, other, version = strategy_records
      child = create(:strategy_version, strategy: own)
      connection.execute("ALTER TABLE strategy_versions DISABLE TRIGGER validate_strategy_version_parent_reference")
      child.update_columns(parent_version_id: version.id)
      connection.execute("ALTER TABLE strategy_versions ENABLE TRIGGER validate_strategy_version_parent_reference")

      expect { repair }.to raise_error(ActiveRecord::MigrationError, /current: 0, parent: 1/)
      expect(child.reload.parent_version_id).to eq(version.id)
      expect(version.reload.strategy_id).to eq(other.id)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "restores the previous logical system access setting after a refused migration" do
    TenantContext.with_system_access do
      own, _other, version = strategy_records
      connection.execute("ALTER TABLE strategies DISABLE TRIGGER validate_strategy_current_version_reference")
      own.update_columns(current_version_id: version.id)
      connection.execute("ALTER TABLE strategies ENABLE TRIGGER validate_strategy_current_version_reference")
    end
    connection.execute("SELECT set_config('paid.bypass_tenant_rls', 'false', true)")

    expect { repair }.to raise_error(ActiveRecord::MigrationError, /current: 1/)
    expect(connection.select_value("SELECT current_setting('paid.bypass_tenant_rls')")).to eq("false")
  end

  def strategy_records
    account = create(:account)
    own = create(:strategy, account:)
    other = create(:strategy, account:)
    [ own, other, create(:strategy_version, strategy: other) ]
  end

  def repair
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end
end
