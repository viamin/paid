# frozen_string_literal: true

class CreateServiceContainers < ActiveRecord::Migration[8.1]
  def change
    create_table :service_containers do |t|
      t.string :image, null: false
      t.string :name, null: false
      t.integer :port, null: false
      t.jsonb :env, default: {}
      t.string :docker_container_id
      t.string :status, default: "stopped", null: false

      t.timestamps
    end

    add_index :service_containers, :name, unique: true

    create_table :project_service_containers do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :service_container, null: false, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :project_service_containers, [ :project_id, :service_container_id ],
      unique: true, name: "idx_project_service_containers_unique"

    add_column :user_settings, :allowed_service_images, :jsonb,
      default: [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ], null: false

    add_column :agent_runs, :service_container_ids, :jsonb, default: []
    add_column :agent_runs, :service_environment, :jsonb, default: {}
  end
end
