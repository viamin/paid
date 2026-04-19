# frozen_string_literal: true

class CreateTrackerConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :tracker_configurations do |t|
      t.uuid :uuid, null: false, default: "gen_random_uuid()"
      t.string :configurable_type, null: false
      t.bigint :configurable_id, null: false
      t.string :tracker_type, null: false
      t.string :base_url
      t.references :integration_credential, foreign_key: true, null: true
      t.jsonb :project_mapping, default: {}
      t.boolean :enabled, null: false, default: true
      t.references :created_by, foreign_key: { to_table: :users }, null: true

      t.timestamps
    end

    add_index :tracker_configurations, :uuid, unique: true
    add_index :tracker_configurations, [ :configurable_type, :configurable_id ], unique: true,
      name: "index_tracker_configurations_on_configurable"
    add_index :tracker_configurations, :tracker_type
  end
end
