# frozen_string_literal: true

class AddMcpProvisionedServersToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :mcp_provisioned_servers, :jsonb, default: {}, null: false,
      comment: "Materialized MCP server specs (stdio_servers + url_servers) produced by provisioning"
  end
end
