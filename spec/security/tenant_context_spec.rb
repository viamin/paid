# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")

RSpec.describe TenantContext, :tenant_isolation do
  around do |example|
    install_tenant_policies
    example.run
  ensure
    uninstall_tenant_policies
  end

  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  it "filters direct account records through the database policy" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(Project.all).to contain_exactly(project_a)
      end
    end
  end

  it "filters project-owned records through the database policy" do
    run_a = described_class.with_system_access { create(:agent_run, project: create(:project, account: account_a)) }
    described_class.with_system_access { create(:agent_run, project: create(:project, account: account_b)) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(AgentRun.all).to contain_exactly(run_a)
      end
    end
  end

  it "does not return tenant rows without tenant context" do
    described_class.with_system_access { create(:project, account: account_a) }

    as_restricted_role do
      described_class.clear!
      expect(Project.all).to be_empty
    end
  end

  it "uses tenant-specific Qdrant collection names" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    expect(Knowledge::Qdrant::CollectionManager.collection_name(project_a))
      .to eq("account_#{account_a.id}_project_#{project_a.id}")
    expect(Knowledge::Qdrant::CollectionManager.collection_name(project_b))
      .to eq("account_#{account_b.id}_project_#{project_b.id}")
  end

  it "rejects cross-tenant project join rows at the database policy" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    user_b = described_class.with_system_access { create(:user, account: account_b) }
    mcp_server_b = described_class.with_system_access { create(:mcp_server_definition, account: account_b) }
    service_container_b = described_class.with_system_access { create(:service_container, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect_rls_rejection { insert_project_membership(project_a, user_b) }
        expect_rls_rejection { insert_project_mcp_server(project_a, mcp_server_b) }
        expect_rls_rejection { insert_project_service_container(project_a, service_container_b) }
      end
    end
  end

  def as_restricted_role
    ActiveRecord::Base.connection.execute("SET ROLE paid_rls_spec")
    yield
  ensure
    ActiveRecord::Base.connection.execute("RESET ROLE")
  end

  def install_tenant_policies
    ActiveRecord::Migration.suppress_messages do
      EnableTenantRowLevelSecurity.new.down
      EnableTenantRowLevelSecurity.new.up
    end
    ActiveRecord::Base.connection.execute("RESET ROLE")
    cleanup_restricted_role
    ActiveRecord::Base.connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
    ActiveRecord::Base.connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO paid_rls_spec")
  end

  def uninstall_tenant_policies
    ActiveRecord::Base.connection.execute("RESET ROLE")
    cleanup_restricted_role
    ActiveRecord::Migration.suppress_messages do
      EnableTenantRowLevelSecurity.new.down
    end
  end

  def cleanup_restricted_role
    return unless ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'paid_rls_spec'")

    ActiveRecord::Base.connection.execute("DROP OWNED BY paid_rls_spec")
    ActiveRecord::Base.connection.execute("DROP ROLE IF EXISTS paid_rls_spec")
  end

  def expect_rls_rejection
    ActiveRecord::Base.connection.execute("SAVEPOINT rls_rejection")
    expect { yield }.to raise_error(ActiveRecord::StatementInvalid, /row-level security policy/)
  ensure
    ActiveRecord::Base.connection.execute("ROLLBACK TO SAVEPOINT rls_rejection")
    ActiveRecord::Base.connection.execute("RELEASE SAVEPOINT rls_rejection")
  end

  def insert_project_membership(project, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_memberships (project_id, user_id, role, created_at, updated_at)
      VALUES (#{project.id}, #{user.id}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_project_mcp_server(project, mcp_server)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_mcp_servers (project_id, mcp_server_definition_id, created_at, updated_at)
      VALUES (#{project.id}, #{mcp_server.id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_project_service_container(project, service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_service_containers (project_id, service_container_id, created_at, updated_at)
      VALUES (#{project.id}, #{service_container.id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end
end
