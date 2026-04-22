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

  it "allows tenant reads but blocks tenant writes for global prompts and style guides" do
    global_prompt = described_class.with_system_access { create(:prompt, :global, :with_version) }
    tenant_prompt = described_class.with_system_access { create(:prompt, :for_account, account: account_a) }
    global_style_guide = described_class.with_system_access { create(:style_guide, :global) }
    tenant_style_guide = described_class.with_system_access { create(:style_guide, :for_account, account: account_a) }

    as_restricted_role do
      described_class.with(account_a) do
        expect_optional_account_reads_allowed(global_prompt, tenant_prompt, global_style_guide, tenant_style_guide)
        expect_global_prompt_writes_blocked(global_prompt)
        expect_global_prompt_version_writes_blocked(global_prompt.current_version)
        expect_global_style_guide_writes_blocked(global_style_guide)
        expect_rls_rejection { insert_prompt(account_id: nil) }
        expect_rls_rejection { insert_prompt_version(prompt: global_prompt) }
        expect_rls_rejection { insert_style_guide(account_id: nil) }
      end
    end

    described_class.with_system_access do
      expect(global_prompt.reload.name).not_to eq("Changed Global Prompt")
      expect(global_style_guide.reload.name).not_to eq("Changed Global Guide")
    end
  end

  it "requires optional-account project writes to stay inside the tenant account" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect { insert_prompt(account_id: account_a.id) }.not_to raise_error
        expect { insert_prompt(account_id: account_a.id, project_id: project_a.id) }.not_to raise_error
        tenant_prompt = described_class.with_system_access { create(:prompt, :for_account, account: account_a) }
        expect { insert_prompt_version(prompt: tenant_prompt) }.not_to raise_error
        expect { insert_style_guide(account_id: account_a.id) }.not_to raise_error
        expect { insert_style_guide(account_id: account_a.id, project_id: project_a.id) }.not_to raise_error
        expect_rls_rejection { insert_prompt(account_id: account_a.id, project_id: project_b.id) }
        expect_rls_rejection { insert_style_guide(account_id: account_a.id, project_id: project_b.id) }
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

  def expect_optional_account_reads_allowed(global_prompt, tenant_prompt, global_style_guide, tenant_style_guide)
    expect(Prompt.where(id: [ global_prompt.id, tenant_prompt.id ])).to contain_exactly(global_prompt, tenant_prompt)
    expect(StyleGuide.where(id: [ global_style_guide.id, tenant_style_guide.id ]))
      .to contain_exactly(global_style_guide, tenant_style_guide)
  end

  def expect_global_prompt_writes_blocked(prompt)
    expect(update_prompt_name(prompt, "Changed Global Prompt")).to eq(0)
    expect(delete_prompt(prompt)).to eq(0)
  end

  def expect_global_prompt_version_writes_blocked(prompt_version)
    expect(update_prompt_version_template(prompt_version, "Changed template")).to eq(0)
    expect(delete_prompt_version(prompt_version)).to eq(0)
  end

  def expect_global_style_guide_writes_blocked(style_guide)
    expect(update_style_guide_name(style_guide, "Changed Global Guide")).to eq(0)
    expect(delete_style_guide(style_guide)).to eq(0)
  end

  def update_prompt_name(prompt, name)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE prompts
      SET name = #{quote(name)}
      WHERE id = #{prompt.id}
    SQL
  end

  def delete_prompt(prompt)
    ActiveRecord::Base.connection.delete("DELETE FROM prompts WHERE id = #{prompt.id}")
  end

  def update_prompt_version_template(prompt_version, template)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE prompt_versions
      SET template = #{quote(template)}
      WHERE id = #{prompt_version.id}
    SQL
  end

  def delete_prompt_version(prompt_version)
    ActiveRecord::Base.connection.delete("DELETE FROM prompt_versions WHERE id = #{prompt_version.id}")
  end

  def update_style_guide_name(style_guide, name)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE style_guides
      SET name = #{quote(name)}
      WHERE id = #{style_guide.id}
    SQL
  end

  def delete_style_guide(style_guide)
    ActiveRecord::Base.connection.delete("DELETE FROM style_guides WHERE id = #{style_guide.id}")
  end

  def insert_prompt(account_id:, project_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO prompts (account_id, project_id, slug, name, category, active, created_at, updated_at)
      VALUES (
        #{sql_value(account_id)},
        #{sql_value(project_id)},
        #{quote("rls.prompt-#{SecureRandom.hex(4)}")},
        'RLS Prompt',
        'coding',
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_prompt_version(prompt:)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO prompt_versions (prompt_id, version, template, variables, created_at)
      VALUES (
        #{prompt.id},
        #{SecureRandom.random_number(100_000) + 1},
        'RLS template',
        '{}',
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_style_guide(account_id:, project_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO style_guides (account_id, project_id, name, raw_content, active, created_at, updated_at)
      VALUES (
        #{sql_value(account_id)},
        #{sql_value(project_id)},
        #{quote("RLS Style Guide #{SecureRandom.hex(4)}")},
        '# Style Guide',
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def sql_value(value)
    value.nil? ? "NULL" : value
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
