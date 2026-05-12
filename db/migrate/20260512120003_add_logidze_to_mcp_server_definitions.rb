# frozen_string_literal: true

class AddLogidzeToMcpServerDefinitions < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_server_definitions, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_mcp_server_definitions, on: :mcp_server_definitions
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_mcp_server_definitions" on "mcp_server_definitions";
        SQL
      end
    end
  end
end
