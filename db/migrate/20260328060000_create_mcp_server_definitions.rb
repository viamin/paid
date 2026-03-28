# frozen_string_literal: true

class CreateMcpServerDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_server_definitions do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, limit: 255, null: false
      t.string :transport, limit: 50, null: false
      t.string :install_type, limit: 50, null: false
      t.string :command, limit: 500
      t.jsonb :args, default: [], null: false
      t.string :url, limit: 2048
      t.string :image, limit: 500
      t.jsonb :env, default: {}, null: false
      t.boolean :enabled, default: true, null: false
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :mcp_server_definitions, [ :account_id, :name ], unique: true
    add_index :mcp_server_definitions, [ :account_id, :enabled ]
  end
end
