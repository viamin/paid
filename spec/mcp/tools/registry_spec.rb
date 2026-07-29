# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:write_tool_names) do
    %w[
      trigger_agent_run
      cancel_agent_run
      record_change_intent
      invite_account_member
      update_account_membership
      remove_account_membership
      update_user_settings
      update_tenant_settings
      update_project_settings
      apply_configuration_profile
      create_provider_api_key
      update_provider_api_key
      remove_provider_api_key
      create_mcp_server_definition
      update_mcp_server_definition
      remove_mcp_server_definition
      operator_suspend_account
      operator_reactivate_account
      operator_deactivate_account
      operator_recompress_style_guides
    ]
  end

  describe ".definitions_for" do
    it "includes write tools for a user with a project-level member role" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :viewer, account: account)
      create(:project_membership, :member, user: user, project: project)

      definitions = described_class.definitions_for(user: user)

      expect(definitions.map { |definition| definition[:name] }).to include(
        "trigger_agent_run",
        "cancel_agent_run",
        "search_intents",
        "get_intent"
      )
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

      all_definition_names = described_class.definitions_for(user: user).map { |definition| definition[:name] }
      read_only_definition_names = described_class.read_only_definitions_for(user: user).map { |definition| definition[:name] }

      expect(read_only_definition_names).to match_array(all_definition_names - write_tool_names)
      expect(read_only_definition_names & write_tool_names).to be_empty
    end
  end

  describe ".chat_definitions_for" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:user) { create(:user, :owner, account: account) }
    let(:chat_session) { build(:chat_session, account: account, created_by: user, project: project) }

    before { create(:project_membership, :member, user: user, project: project) }

    it "advertises write tools so the chat agent can propose them" do
      names = described_class.chat_definitions_for(user: user, session: chat_session).map { |definition| definition[:name] }

      expect(names).to include(
        "trigger_agent_run",
        "cancel_agent_run",
        "record_change_intent",
        "update_user_settings",
        "list_configuration_profiles",
        "plan_configuration_profile",
        "apply_configuration_profile",
        "search_intents",
        "get_intent"
      )
    end

    it "strips the confirmed argument from write-tool schemas so the model cannot self-confirm" do
      trigger_definition = described_class.chat_definitions_for(user: user, session: chat_session).find { |definition| definition[:name] == "trigger_agent_run" }
      schema = trigger_definition[:inputSchema]

      expect(schema[:properties]).not_to have_key(:confirmed)
      expect(schema[:required]).not_to include("confirmed")
    end

    it "leaves read-only tool schemas untouched" do
      get_project = described_class.chat_definitions_for(user: user, session: chat_session).find { |definition| definition[:name] == "get_project" }

      expect(get_project[:inputSchema]).to eq(Tools::GetProject.definition[:inputSchema])
    end

    it "does not advertise record_change_intent when the session has no current project" do
      session_without_project = build(:chat_session, account: account, created_by: user)

      names = described_class.chat_definitions_for(user: user, session: session_without_project).map { |definition| definition[:name] }

      expect(names).not_to include("record_change_intent")
    end

    it "does not advertise record_change_intent when no session is provided" do
      names = described_class.chat_definitions_for(user: user).map { |definition| definition[:name] }

      expect(names).not_to include("record_change_intent")
    end

    it "does not advertise record_change_intent when the user cannot update the session's project" do
      viewer = create(:user, :viewer, account: account)
      session = build(:chat_session, account: account, created_by: viewer, project: project)

      names = described_class.chat_definitions_for(user: viewer, session: session).map { |definition| definition[:name] }

      expect(names).not_to include("record_change_intent")
    end
  end

  describe ".write_tool?" do
    it "returns true for known write tools and false otherwise" do
      expect(described_class.write_tool?("trigger_agent_run")).to be(true)
      expect(described_class.write_tool?("operator_suspend_account")).to be(true)
      expect(described_class.write_tool?("get_project")).to be(false)
      expect(described_class.write_tool?("does_not_exist")).to be(false)
    end
  end

  describe ".dispatch_read_only" do
    it "rejects write tools even when the user is authorized to see them in the full registry" do
      account = create(:account)
      project = create(:project, account: account)
      user = create(:user, :owner, account: account)
      create(:project_membership, :member, user: user, project: project)

      expect {
        described_class.dispatch_read_only(
          name: "trigger_agent_run",
          arguments: {},
          user: user,
          session: build(:chat_session, account: account, created_by: user)
        )
      }.to raise_error(ArgumentError, "Unknown tool: trigger_agent_run")
    end
  end

  describe "write-operation audit" do
    it "flags the known write tools" do
      flagged_write_tool_names = described_class.all.select(&:write_operation?).map(&:tool_name)

      expect(flagged_write_tool_names).to match_array(write_tool_names)
    end
  end
end
