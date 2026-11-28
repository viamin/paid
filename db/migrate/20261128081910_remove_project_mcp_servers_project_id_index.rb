# frozen_string_literal: true

# Removes the redundant single-column project_id index: the unique
# idx_project_mcp_servers_unique on (project_id, mcp_server_definition_id)
# covers the same project_id access path with its leading column (#5790).
class RemoveProjectMcpServersProjectIdIndex < ActiveRecord::Migration[8.1] # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  INDEX_NAME = "index_project_mcp_servers_on_project_id"
  COVERING_INDEX_NAME = "idx_project_mcp_servers_unique"

  def up
    return unless covering_index_exists?
    return unless index_exists?(:project_mcp_servers, :project_id, name: INDEX_NAME)

    remove_index :project_mcp_servers, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    return if index_exists?(:project_mcp_servers, :project_id, name: INDEX_NAME)

    add_index :project_mcp_servers, :project_id, name: INDEX_NAME, algorithm: :concurrently
  end

  private

  def covering_index_exists?
    index_exists?(:project_mcp_servers, [ :project_id, :mcp_server_definition_id ],
      unique: true, name: COVERING_INDEX_NAME)
  end
end
