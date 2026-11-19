# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategy, :tenant_isolation do
  let(:account) { TenantContext.with_system_access { create(:account) } }
  let(:other_account) { TenantContext.with_system_access { create(:account) } }

  before do
    role = ActiveRecord::Base.connection.select_one("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
    raise "Tenant policy proof requires a normal application role" unless role.values.all?(false)
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "plans reads for every protected table without recursive policy failures" do
    connection = ActiveRecord::Base.connection
    tables = connection.select_values(<<~SQL)
      SELECT relname FROM pg_class
      JOIN pg_namespace ON pg_namespace.oid = relnamespace
      WHERE nspname = 'public' AND relkind = 'r' AND relrowsecurity
      ORDER BY relname
    SQL
    expect(tables).to include("strategies", "strategy_versions")
    tables.each do |table|
      expect {
        connection.transaction(requires_new: true) do
          connection.select_all("SELECT 1 FROM #{connection.quote_table_name(table)} LIMIT 0")
        end
      }.not_to raise_error
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "shows own and global strategy records while hiding other tenant records" do
    own, own_version = strategy_records(account:)
    foreign, foreign_version = strategy_records(account: other_account)
    global, global_version = strategy_records(account: nil)

    TenantContext.with(account) do
      expect(described_class.where(id: [ own.id, foreign.id, global.id ]).pluck(:id)).to contain_exactly(own.id, global.id)
      expect(StrategyVersion.where(id: [ own_version.id, foreign_version.id, global_version.id ]).pluck(:id))
        .to contain_exactly(own_version.id, global_version.id)
      expect(own.update_columns(current_version_id: own_version.id)).to be(true)
      expect(own_version.update_columns(promotion_state: "candidate")).to be(true)
      expect(described_class.where(id: [ foreign.id, global.id ]).update_all(name: "Changed")).to eq(0)
      expect(StrategyVersion.where(id: [ foreign_version.id, global_version.id ]).delete_all).to eq(0)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "keeps tenant data hidden without an account while retaining global reads" do
    own, own_version = strategy_records(account:)
    global, global_version = strategy_records(account: nil)

    TenantContext.with(nil) do
      expect(described_class.where(id: [ own.id, global.id ]).pluck(:id)).to eq([ global.id ])
      expect(StrategyVersion.where(id: [ own_version.id, global_version.id ]).pluck(:id)).to eq([ global_version.id ])
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-013
  it "rejects a current version from another strategy even through direct SQL" do
    own, own_version = strategy_records(account:)
    _other, other_version = strategy_records(account:)
    _foreign, foreign_version = strategy_records(account: other_account)

    TenantContext.with(account) do
      [ other_version, foreign_version ].each do |version|
        expect_scope_violation { own.update_columns(current_version_id: version.id) }
      end
      expect(own.reload.current_version_id).to be_nil
      expect(own.update_columns(current_version_id: own_version.id)).to be(true)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-013
  it "rejects a parent version from another strategy even through direct SQL" do
    own, own_version = strategy_records(account:)
    _other, other_version = strategy_records(account:)
    _foreign, foreign_version = strategy_records(account: other_account)

    TenantContext.with(account) do
      [ other_version, foreign_version ].each do |version|
        expect_scope_violation { own_version.update_columns(parent_version_id: version.id) }
      end
      parent = create(:strategy_version, strategy: own)
      expect(own_version.update_columns(parent_version_id: parent.id)).to be(true)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-013
  it "prevents reassigning a version still used as another strategy's current version" do
    own, version = strategy_records(account:)
    other, = strategy_records(account:)

    TenantContext.with(account) do
      own.update_columns(current_version_id: version.id)
      expect_scope_violation { version.update_columns(strategy_id: other.id) }
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-013
  it "prevents reassigning a version with children bound to its original strategy" do
    own, parent = strategy_records(account:)
    other, = strategy_records(account:)

    TenantContext.with(account) do
      create(:strategy_version, strategy: own, parent_version: parent)
      expect_scope_violation { parent.update_columns(strategy_id: other.id) }
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-013
  it "retains structural reference ownership during explicit system access" do
    own, version = strategy_records(account:)
    _foreign, foreign_version = strategy_records(account: other_account)

    TenantContext.with_system_access do
      expect_scope_violation { own.update_columns(current_version_id: foreign_version.id) }
      expect_scope_violation { version.update_columns(parent_version_id: foreign_version.id) }
    end
  end

  def strategy_records(account:)
    TenantContext.with_system_access do
      strategy = create(:strategy, account:)
      [ strategy, create(:strategy_version, strategy:) ]
    end
  end

  def expect_scope_violation
    expect {
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    }.to raise_error(ActiveRecord::StatementInvalid, /must belong|cannot change/)
  end
end
