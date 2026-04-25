# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162135_add_account_to_service_containers")
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260425113212_enable_rls_on_knowledge_usage_stats")
require Rails.root.join("db/migrate/20260425060000_enable_rls_on_notification_rule_states")

RSpec.describe AddAccountToServiceContainers, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:rls_migration) { EnableTenantRowLevelSecurity.new }
  let(:knowledge_rls_migration) { EnableRlsOnKnowledgeUsageStats.new }
  let(:notification_rls_migration) { EnableRlsOnNotificationRuleStates.new }

  include MigrationSpecHelpers

  before do
    truncate_migration_test_data

    if tenant_policy_count.positive?
      knowledge_rls_migration.down if knowledge_usage_stats_has_rls?
      notification_rls_migration.down
      rls_migration.down
    end
    restore_service_container_account_reference unless service_containers_have_account_reference?
    migration.down
    ServiceContainer.reset_column_information
  end

  include MigrationSpecHelpers

  after do
    truncate_migration_test_data

    restore_service_container_account_reference unless service_containers_have_account_reference?
    if tenant_policy_count.zero?
      rls_migration.up
      notification_rls_migration.up
      knowledge_rls_migration.up unless knowledge_usage_stats_has_rls?
    end
    ServiceContainer.reset_column_information
  end

  it "duplicates shared service containers per account and rewires project joins" do
    first_project, second_project, service_container = create_shared_service_container

    migration.up
    ServiceContainer.reset_column_information

    first_project_service_container = project_service_container_for(first_project)
    second_project_service_container = project_service_container_for(second_project)

    expect(first_project_service_container.account_id).to eq(first_project.account_id)
    expect(second_project_service_container.account_id).to eq(second_project.account_id)
    expect(first_project_service_container.name).to eq(service_container["name"])
    expect(second_project_service_container.name).to eq(service_container["name"])
    expect(first_project_service_container.id).not_to eq(second_project_service_container.id)
    expect(first_project_service_container.status).to eq("running")
    expect(first_project_service_container.docker_container_id).to eq("container-1")
    expect(second_project_service_container.status).to eq("stopped")
    expect(second_project_service_container.docker_container_id).to be_nil
    expect(metric_count_for(first_project_service_container)).to eq(1)
    expect(metric_count_for(second_project_service_container)).to eq(1)
  end

  it "collapses per-account copies before restoring the global name index on rollback" do
    create_shared_service_container

    migration.up

    expect { migration.down }.not_to raise_error
    ServiceContainer.reset_column_information

    expect(service_container_count).to eq(1)
    expect(service_container_metric_count).to eq(1)
    expect(project_service_container_count).to eq(2)
    expect(distinct_joined_service_container_count).to eq(1)
  end

  private

  def create_shared_service_container
    first_project = create(:project)
    second_project = create(:project)
    service_container = create_service_container_without_account

    create_project_service_container(first_project, service_container)
    create_project_service_container(second_project, service_container)
    create_service_container_metric(service_container)

    [ first_project, second_project, service_container ]
  end

  def create_service_container_without_account
    result = ActiveRecord::Base.connection.exec_query(<<~SQL.squish)
      INSERT INTO service_containers (
        image,
        name,
        port,
        env,
        docker_container_id,
        status,
        created_at,
        updated_at
      )
      VALUES (
        'postgres:16',
        'shared-postgres',
        5432,
        '{"POSTGRES_USER":"agent"}',
        'container-1',
        'running',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
      RETURNING id, name
    SQL

    result.first
  end

  def create_project_service_container(project, service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_service_containers (
        project_id,
        service_container_id,
        created_at,
        updated_at
      )
      VALUES (
        #{project.id},
        #{service_container["id"]},
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def create_service_container_metric(service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO service_container_metrics (
        service_container_id,
        container_id,
        cpu_percent,
        memory_bytes,
        memory_limit_bytes,
        memory_percent,
        recorded_at,
        created_at,
        updated_at
      )
      VALUES (
        #{service_container["id"]},
        'container-1',
        1.5,
        1024,
        2048,
        50.0,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def project_service_container_for(project)
    project.service_containers.reload.sole
  end

  def metric_count_for(service_container)
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT COUNT(*)
      FROM service_container_metrics
      WHERE service_container_id = #{service_container.id}
    SQL
  end

  def service_container_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM service_containers")
  end

  def service_container_metric_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM service_container_metrics")
  end

  def project_service_container_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM project_service_containers")
  end

  def distinct_joined_service_container_count
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(DISTINCT service_container_id) FROM project_service_containers"
    )
  end

  def knowledge_usage_stats_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'knowledge_usage_stats' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def tenant_policy_count
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE policyname = 'tenant_isolation'"
    ).to_i
  end

  def service_containers_have_account_reference?
    connection = ActiveRecord::Base.connection
    connection.column_exists?(:service_containers, :account_id) &&
      connection.foreign_key_exists?(:service_containers, :accounts)
  end

  def restore_service_container_account_reference
    connection = ActiveRecord::Base.connection
    connection.remove_index(:service_containers, column: [ :account_id, :name ], if_exists: true)
    connection.remove_column(:service_containers, :account_id) if connection.column_exists?(:service_containers, :account_id)
    migration.up
  end
end
