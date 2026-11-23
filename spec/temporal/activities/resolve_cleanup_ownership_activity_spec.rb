# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolveCleanupOwnershipActivity do
  # @spec TEMPORAL-ORCHESTRATION-016
  it "does not invent cleanup ownership for an unprovisioned acceptance audit" do
    agent_run = create(:agent_run, goal: "analyze_issue")

    expect(described_class.new.execute(agent_run_id: agent_run.id)).to eq(
      container: false, mcp_servers: false, services: false, worktree: false, janitor: false
    )
  end

  # @spec TEMPORAL-ORCHESTRATION-016
  it "retains cleanup ownership for persisted resources after a resumed audit" do
    agent_run = create(:agent_run, container_id: "resumed-container", service_container_ids: [ "postgres-1" ],
      mcp_sidecar_container_ids: [ "mcp-1" ])
    create(:worktree, project: agent_run.project, agent_run: agent_run, status: "active")
    create(:execution_resource, agent_run: agent_run)

    expect(described_class.new.execute(agent_run_id: agent_run.id)).to eq(
      container: true, mcp_servers: true, services: true, worktree: true, janitor: true
    )
  end
end
