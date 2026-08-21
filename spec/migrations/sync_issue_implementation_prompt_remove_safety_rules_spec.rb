# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260813024216_sync_issue_implementation_prompt_remove_safety_rules")

RSpec.describe SyncIssueImplementationPromptRemoveSafetyRules, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: described_class::PROMPT_SLUG).destroy_all
    end
  end

  def seed_prompt
    create(
      :prompt,
      :global,
      slug: described_class::PROMPT_SLUG,
      name: "Coding: Issue Implementation"
    )
  end

  it "promotes the updated template for the persisted global prompt" do
    prompt = seed_prompt
    previous_version = prompt.create_version!(
      template: "old {{title}}",
      variables: [ { "name" => "title" } ],
      created_by: "seed"
    )

    expect {
      migration.up
    }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.reload.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to eq(described_class::TEMPLATE)
    expect(prompt.current_version.variables).to eq(described_class::VARIABLES)
    expect(prompt.current_version.created_by).to eq("migration")
    expect(prompt.current_version.change_notes).to eq(described_class::CHANGE_NOTES)
  end

  it "is a no-op when the prompt is already synced" do
    prompt = seed_prompt
    prompt.create_version!(
      template: described_class::TEMPLATE,
      variables: described_class::VARIABLES,
      created_by: "seed"
    )

    expect { migration.up }.not_to change(PromptVersion, :count)
  end

  it "is a no-op when the global prompt does not exist" do
    expect { migration.up }.not_to raise_error
  end

  # Global prompts are readable by every tenant but writable by none: the
  # tenant_isolation_update policy requires `prompts.account_id =
  # paid_current_account_id()`, which no account satisfies for an account-less
  # row. Prompt#create_version! takes a row lock (SELECT ... FOR UPDATE), which
  # PostgreSQL evaluates against that write policy, so a data migration that
  # rewrites a global prompt must declare system access or die with
  # RecordNotFound mid-migration.
  #
  # @spec POSTGRESQL-PERSISTENCE-008
  context "with tenant RLS policies installed", :tenant_isolation do
    around do |example|
      installed = install_prompt_policies
      example.run
    ensure
      uninstall_prompt_policies if installed
    end

    it "syncs the global prompt without ambient tenant bypass" do
      prompt = TenantContext.with_system_access do
        seeded = seed_prompt
        seeded.create_version!(
          template: "old {{title}}",
          variables: [ { "name" => "title" } ],
          created_by: "seed"
        )
        seeded
      end

      TenantContext.clear!

      expect { migration.up }.not_to raise_error

      TenantContext.with_system_access do
        expect(prompt.reload.current_version.template).to eq(described_class::TEMPLATE)
        expect(prompt.current_version.created_by).to eq("migration")
      end
    end
  end

  def rls_tables
    %w[prompts prompt_versions]
  end

  def install_prompt_policies
    return false if rls_tables.any? { |table| policies_for(table).any? }

    rls_migration = EnableTenantRowLevelSecurity.new
    ActiveRecord::Migration.suppress_messages do
      rls_migration.send(:safety_assured) do
        rls_migration.send(:enable_optional_account_policy, "prompts")
        rls_migration.send(
          :enable_read_write_policy,
          "prompt_versions",
          rls_migration.send(:prompt_condition, "prompt_versions"),
          rls_migration.send(:prompt_write_condition, "prompt_versions")
        )
      end
    end
    true
  end

  def uninstall_prompt_policies
    rls_migration = EnableTenantRowLevelSecurity.new
    ActiveRecord::Migration.suppress_messages do
      rls_migration.send(:safety_assured) do
        rls_tables.each do |table|
          rls_migration.send(:drop_policies, table)
          rls_migration.execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
          rls_migration.execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
        end
      end
    end
  end

  def policies_for(table)
    ActiveRecord::Base.connection.select_values(
      ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, table ])
        SELECT polname FROM pg_policy
        JOIN pg_class ON pg_class.oid = pg_policy.polrelid
        WHERE pg_class.relname = ?
      SQL
    )
  end
end
