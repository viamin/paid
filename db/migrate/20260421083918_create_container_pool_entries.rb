# frozen_string_literal: true

class CreateContainerPoolEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :container_pool_entries do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify }
      t.string :container_id, limit: 128
      t.string :status, limit: 20, null: false
      t.string :workspace_volume, limit: 128, null: false
      t.string :image, null: false
      t.string :network, limit: 64, null: false
      t.timestamp :warmed_at
      t.timestamp :claimed_at
      t.text :last_error

      t.timestamps
    end

    add_index :container_pool_entries, [ :project_id, :status, :warmed_at ]
    add_index :container_pool_entries, :container_id, unique: true, where: "container_id IS NOT NULL"
    add_index :container_pool_entries, :workspace_volume, unique: true
  end
end
