# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, "#snapshot_mcp_servers" do
  it "snapshots enabled MCP servers from the project on create" do
    account = create(:account)
    project = create(:project, account: account)
    definition = create(:mcp_server_definition,
      account: account,
      name: "fs-server",
      transport: "stdio",
      install_type: "npx",
      command: "@modelcontextprotocol/server-filesystem",
      args: [ "/workspace" ])
    create(:project_mcp_server, project: project, mcp_server_definition: definition)

    agent_run = create(:agent_run, project: project)

    expect(agent_run.mcp_server_snapshot).to eq([ definition.to_snapshot ])
  end

  it "excludes disabled MCP servers" do
    account = create(:account)
    project = create(:project, account: account)
    enabled = create(:mcp_server_definition, account: account, name: "enabled-server")
    disabled = create(:mcp_server_definition, :disabled, account: account, name: "disabled-server")
    create(:project_mcp_server, project: project, mcp_server_definition: enabled)
    create(:project_mcp_server, project: project, mcp_server_definition: disabled)

    agent_run = create(:agent_run, project: project)

    names = agent_run.mcp_server_snapshot.map { |s| s["name"] }
    expect(names).to eq([ "enabled-server" ])
  end

  it "stores an empty array when no MCP servers are associated" do
    project = create(:project)
    agent_run = create(:agent_run, project: project)

    expect(agent_run.mcp_server_snapshot).to eq([])
  end

  it "does not overwrite a pre-set snapshot" do
    project = create(:project)
    pre_set = [ { "name" => "pre-existing", "transport" => "stdio", "install_type" => "npx", "command" => "test" } ]

    agent_run = create(:agent_run, project: project, mcp_server_snapshot: pre_set)

    expect(agent_run.mcp_server_snapshot).to eq(pre_set)
  end

  it "snapshot is immutable after creation (source changes do not propagate)" do
    account = create(:account)
    project = create(:project, account: account)
    definition = create(:mcp_server_definition, account: account, name: "original-name")
    create(:project_mcp_server, project: project, mcp_server_definition: definition)

    agent_run = create(:agent_run, project: project)
    original_snapshot = agent_run.mcp_server_snapshot.deep_dup

    definition.update!(name: "renamed-server")
    agent_run.reload

    expect(agent_run.mcp_server_snapshot).to eq(original_snapshot)
  end

  it "snapshot column is read-only after creation" do
    project = create(:project)
    agent_run = create(:agent_run, project: project)

    expect {
      agent_run.update!(mcp_server_snapshot: [ { "name" => "injected" } ])
    }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end
end
