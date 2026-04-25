# frozen_string_literal: true

class AddAccountToServiceContainers < ActiveRecord::Migration[8.1]
  def up
    add_reference :service_containers, :account, foreign_key: true
    remove_index :service_containers, name: "index_service_containers_on_name"

    execute <<~SQL.squish
      WITH container_accounts AS (
        SELECT
          project_service_containers.service_container_id,
          projects.account_id,
          MIN(projects.id) AS first_project_id
        FROM project_service_containers
        INNER JOIN projects ON projects.id = project_service_containers.project_id
        GROUP BY project_service_containers.service_container_id, projects.account_id
      ),
      primary_accounts AS (
        SELECT DISTINCT ON (service_container_id)
          service_container_id,
          account_id
        FROM container_accounts
        ORDER BY service_container_id, first_project_id, account_id
      )
      UPDATE service_containers
      SET account_id = primary_accounts.account_id
      FROM primary_accounts
      WHERE primary_accounts.service_container_id = service_containers.id
    SQL

    execute <<~SQL.squish
      WITH container_accounts AS (
        SELECT
          project_service_containers.service_container_id,
          projects.account_id,
          MIN(projects.id) AS first_project_id
        FROM project_service_containers
        INNER JOIN projects ON projects.id = project_service_containers.project_id
        GROUP BY project_service_containers.service_container_id, projects.account_id
      ),
      primary_accounts AS (
        SELECT DISTINCT ON (service_container_id)
          service_container_id,
          account_id
        FROM container_accounts
        ORDER BY service_container_id, first_project_id, account_id
      ),
      secondary_accounts AS (
        SELECT container_accounts.service_container_id, container_accounts.account_id
        FROM container_accounts
        INNER JOIN primary_accounts
          ON primary_accounts.service_container_id = container_accounts.service_container_id
        WHERE container_accounts.account_id != primary_accounts.account_id
      )
      INSERT INTO service_containers (
        account_id,
        image,
        name,
        port,
        env,
        docker_container_id,
        status,
        container_metrics_count,
        avg_cpu_percent,
        avg_memory_bytes,
        peak_cpu_percent,
        peak_memory_bytes,
        created_at,
        updated_at
      )
      SELECT
        secondary_accounts.account_id,
        service_containers.image,
        service_containers.name,
        service_containers.port,
        service_containers.env,
        NULL,
        'stopped',
        service_containers.container_metrics_count,
        service_containers.avg_cpu_percent,
        service_containers.avg_memory_bytes,
        service_containers.peak_cpu_percent,
        service_containers.peak_memory_bytes,
        service_containers.created_at,
        service_containers.updated_at
      FROM secondary_accounts
      INNER JOIN service_containers
        ON service_containers.id = secondary_accounts.service_container_id
    SQL

    execute <<~SQL.squish
      WITH container_accounts AS (
        SELECT
          project_service_containers.service_container_id,
          projects.account_id,
          MIN(projects.id) AS first_project_id
        FROM project_service_containers
        INNER JOIN projects ON projects.id = project_service_containers.project_id
        GROUP BY project_service_containers.service_container_id, projects.account_id
      ),
      primary_accounts AS (
        SELECT DISTINCT ON (service_container_id)
          service_container_id,
          account_id
        FROM container_accounts
        ORDER BY service_container_id, first_project_id, account_id
      )
      INSERT INTO service_container_metrics (
        service_container_id,
        container_id,
        cpu_percent,
        memory_bytes,
        memory_limit_bytes,
        memory_percent,
        pids_count,
        recorded_at,
        created_at,
        updated_at
      )
      SELECT
        account_service_containers.id,
        service_container_metrics.container_id,
        service_container_metrics.cpu_percent,
        service_container_metrics.memory_bytes,
        service_container_metrics.memory_limit_bytes,
        service_container_metrics.memory_percent,
        service_container_metrics.pids_count,
        service_container_metrics.recorded_at,
        service_container_metrics.created_at,
        service_container_metrics.updated_at
      FROM primary_accounts
      INNER JOIN service_containers original_service_containers
        ON original_service_containers.id = primary_accounts.service_container_id
      INNER JOIN service_containers account_service_containers
        ON account_service_containers.name = original_service_containers.name
        AND account_service_containers.account_id != original_service_containers.account_id
      INNER JOIN service_container_metrics
        ON service_container_metrics.service_container_id = original_service_containers.id
    SQL

    execute <<~SQL.squish
      UPDATE project_service_containers
      SET service_container_id = account_service_containers.id
      FROM projects, service_containers original_service_containers, service_containers account_service_containers
      WHERE projects.id = project_service_containers.project_id
        AND original_service_containers.id = project_service_containers.service_container_id
        AND account_service_containers.account_id = projects.account_id
        AND account_service_containers.name = original_service_containers.name
        AND original_service_containers.account_id != projects.account_id
    SQL

    execute <<~SQL.squish
      UPDATE service_containers
      SET account_id = (SELECT id FROM accounts ORDER BY id LIMIT 1)
      WHERE account_id IS NULL
    SQL

    change_column_null :service_containers, :account_id, false
    add_index :service_containers, [ :account_id, :name ], unique: true
  end

  def down
    drop_service_container_tenant_policies

    execute <<~SQL.squish
      WITH primary_service_containers AS (
        SELECT DISTINCT ON (name)
          id,
          name
        FROM service_containers
        ORDER BY name, id
      )
      UPDATE project_service_containers
      SET service_container_id = primary_service_containers.id
      FROM service_containers, primary_service_containers
      WHERE service_containers.id = project_service_containers.service_container_id
        AND primary_service_containers.name = service_containers.name
        AND service_containers.id != primary_service_containers.id
    SQL

    execute <<~SQL.squish
      WITH primary_service_containers AS (
        SELECT DISTINCT ON (name)
          id,
          name
        FROM service_containers
        ORDER BY name, id
      )
      DELETE FROM service_containers
      USING primary_service_containers
      WHERE service_containers.name = primary_service_containers.name
        AND service_containers.id != primary_service_containers.id
    SQL

    remove_index :service_containers, [ :account_id, :name ], if_exists: true
    add_index :service_containers, :name, unique: true unless index_exists?(:service_containers, :name, unique: true)
    remove_reference :service_containers, :account, foreign_key: true
  end

  private

  def drop_service_container_tenant_policies
    %w[
      project_service_containers
      service_container_metrics
      service_containers
    ].each do |table|
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{quote_table_name(table)}"
      execute "ALTER TABLE #{quote_table_name(table)} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{quote_table_name(table)} DISABLE ROW LEVEL SECURITY"
    end
  end
end
