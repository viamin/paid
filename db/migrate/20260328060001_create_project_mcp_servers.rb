# frozen_string_literal: true

class CreateProjectMcpServers < ActiveRecord::Migration[8.1]
  def change
    create_table :project_mcp_servers do |t|
      t.references :project, null: false, foreign_key: true
      t.references :mcp_server_definition, null: false, foreign_key: true

      t.timestamps
    end

    add_index :project_mcp_servers, [ :project_id, :mcp_server_definition_id ],
      unique: true, name: "idx_project_mcp_servers_unique"
  end
end
