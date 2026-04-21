class AddAccountToServiceContainers < ActiveRecord::Migration[8.1]
  def up
    add_reference :service_containers, :account, foreign_key: true

    execute <<~SQL.squish
      UPDATE service_containers
      SET account_id = scoped.account_id
      FROM (
        SELECT DISTINCT ON (project_service_containers.service_container_id)
          project_service_containers.service_container_id,
          projects.account_id
        FROM project_service_containers
        INNER JOIN projects ON projects.id = project_service_containers.project_id
        ORDER BY project_service_containers.service_container_id, projects.id
      ) scoped
      WHERE scoped.service_container_id = service_containers.id
    SQL

    execute <<~SQL.squish
      UPDATE service_containers
      SET account_id = (SELECT id FROM accounts ORDER BY id LIMIT 1)
      WHERE account_id IS NULL
    SQL

    change_column_null :service_containers, :account_id, false
  end

  def down
    remove_reference :service_containers, :account, foreign_key: true
  end
end
