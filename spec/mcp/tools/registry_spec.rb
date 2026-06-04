# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:write_tool_names) do
    %w[
      trigger_agent_run
      cancel_agent_run
      invite_account_member
      update_account_membership
      remove_account_membership
      update_user_settings
      update_tenant_settings
      create_provider_api_key
      update_provider_api_key
      remove_provider_api_key
      create_mcp_server_definition
      update_mcp_server_definition
      remove_mcp_server_definition
    ]
  end

  describe ".definitions_for" do
    it "includes write tools for a user with a project-level member role" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :viewer, account: account)
      create(:project_membership, :member, user: user, project: project)

      definitions = described_class.definitions_for(user: user)

      expect(definitions.map { |definition| definition[:name] }).to include("trigger_agent_run", "cancel_agent_run")
    end

    it "hides run-management write tools when the user lacks run permissions" do
      account = create(:account)
      create(:project, account: account)
      user = create(:user, :viewer, account: account)

      definitions = described_class.definitions_for(user: user)

      expect(definitions.map { |definition| definition[:name] }).not_to include("trigger_agent_run", "cancel_agent_run")
    end

    it "includes account admin write tools even when no project exists" do
      account = create(:account)
      user = create(:user, :owner, account: account)

      definitions = described_class.definitions_for(user: user)

      expect(definitions.map { |definition| definition[:name] }).to include(
        "invite_account_member",
        "update_tenant_settings",
        "create_mcp_server_definition",
        "update_mcp_server_definition"
      )
    end
  end

  describe ".read_only_definitions_for" do
    it "returns every authorized read-only tool definition and excludes write tools" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :owner, account: account)
      create(:project_membership, :member, user: user, project: project)

      definitions = described_class.read_only_definitions_for(user: user)
      definition_names = definitions.map { |definition| definition[:name] }
      expected_names = described_class.all.select { |klass|
        klass.available_to?(user:) && !klass.write_operation?
      }.map(&:tool_name)

      expect(definition_names).to match_array(expected_names)
      expect(definition_names & write_tool_names).to be_empty
    end
  end

  describe "write-operation audit" do
    it "flags the known write tools" do
      flagged_write_tools = described_class.all.select(&:write_operation?).map(&:tool_name)

      expect(flagged_write_tools).to match_array(write_tool_names)
    end
  end
end
