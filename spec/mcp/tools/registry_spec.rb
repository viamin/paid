# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:write_tool_names) do
    %w[
      cancel_agent_run
      create_mcp_server_definition
      create_provider_api_key
      invite_account_member
      remove_account_membership
      remove_mcp_server_definition
      remove_provider_api_key
      trigger_agent_run
      update_account_membership
      update_mcp_server_definition
      update_provider_api_key
      update_tenant_settings
      update_user_settings
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
    it "excludes write tools and keeps authorized read tools" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :owner, account: account)
      create(:project_membership, :member, user: user, project: project)

      all_definition_names = described_class.definitions_for(user: user).map { |definition| definition[:name] }
      read_only_definition_names = described_class.read_only_definitions_for(user: user).map { |definition| definition[:name] }

      expect(read_only_definition_names).to match_array(all_definition_names - write_tool_names)
    end
  end

  describe "write operation audit" do
    it "marks every known write tool as a write operation" do
      flagged_write_tool_names = described_class.all.select(&:write_operation?).map(&:tool_name)

      expect(flagged_write_tool_names).to match_array(write_tool_names)
    end
  end
end
