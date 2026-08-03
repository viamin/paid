# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
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
      write_repo_file
      apply_patch
      git_branch_create
      clone_project
      run_shell
      operator_suspend_account
      operator_reactivate_account
      operator_deactivate_account
      operator_recompress_style_guides
      create_issue
      edit_issue
      set_labels
    ]
  end

  describe ".tools_for" do
    let(:clone_manifest) do
      [
        { project_id: 123, path: "/workspace/repo-one" }
      ]
    end

    # RDR-037: container-only tools stay discoverable in tools/list even before
    # the container is ready. Dispatch-time availability is handled separately.
    %w[none pending provisioning ready failed stopped].each do |capability|
      it "keeps container tools discoverable for #{capability}" do
        session = create(
          :chat_session,
          account: account,
          created_by: user,
          container_capability: capability,
          clone_manifest: clone_manifest,
          container_id: (capability == "ready" ? "container-123" : nil)
        )

        tool_names = described_class.tools_for(session:, user:).map(&:tool_name)

        expect(tool_names).to include("list_projects")
        expect(tool_names).to include("git_status")
        expect(tool_names).to include("git_diff")
        expect(tool_names).to include("write_repo_file")
      end
    end

    it "annotates container tools as temporarily unavailable until the workspace is ready" do
      session = create(
        :chat_session,
        account: account,
        created_by: user,
        container_capability: "pending",
        clone_manifest: clone_manifest
      )

      definitions = described_class.mcp_definitions_for(user: user, session: session)
      git_status_definition = definitions.find { |definition| definition[:name] == "git_status" }

      expect(git_status_definition[:annotations]).to include(
        temporaryUnavailable: true,
        availability: include(
          type: "container_capability",
          state: "pending",
          retryable: true,
          message: Containers::CapabilityMessages.unavailable_for("pending"),
          expectedBehavior: "invoking_returns_retryable_unavailable"
        )
      )
    end

    it "removes the temporary-unavailable annotation once the workspace is ready" do
      session = create(
        :chat_session,
        account: account,
        created_by: user,
        container_capability: "ready",
        clone_manifest: clone_manifest,
        container_id: "container-123"
      )

      definitions = described_class.mcp_definitions_for(user: user, session: session)
      git_status_definition = definitions.find { |definition| definition[:name] == "git_status" }

      expect(git_status_definition).not_to have_key(:annotations)
    end

    it "omits container tools when the session has no clone manifest" do
      session = create(:chat_session, account: account, created_by: user, container_capability: "pending")

      tool_names = described_class.tools_for(session:, user:).map(&:tool_name)

      expect(tool_names).to include("list_projects")
      expect(tool_names).not_to include("git_status", "git_diff", "write_repo_file")
    end

    it "continues to apply Pundit-backed availability filters" do
      viewer = create(:user, :viewer, account: account)
      session = create(:chat_session, account: account, created_by: viewer, container_capability: "ready", clone_manifest: clone_manifest, container_id: "container-123")

      tool_names = described_class.tools_for(session:, user: viewer).map(&:tool_name)

      expect(tool_names).to include("list_projects")
      expect(tool_names).not_to include("trigger_agent_run")
      expect(tool_names).not_to include("cancel_agent_run")
    end
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

  describe ".mcp_definitions_for" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account:) }
    let(:user) { create(:user, :owner, account:) }

    around do |example|
      original_emails = ENV["PAID_OPERATOR_EMAILS"]
      ENV["PAID_OPERATOR_EMAILS"] = user.email
      example.run
    ensure
      ENV["PAID_OPERATOR_EMAILS"] = original_emails
    end

    it "advertises only read-only tools on the raw MCP surface" do
      create(:project_membership, :member, user: user, project: project)

      definitions = described_class.mcp_definitions_for(user: user)
      names = definitions.map { |definition| definition[:name] }

      expect(names).to include("list_projects", "get_project", "operator_console_inventory")
      expect(names).not_to include("trigger_agent_run", "operator_suspend_account")
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

    # RDR-028: the per-tool `confirmed` argument must be stripped from every
    # advertised write-tool schema — not just operator tools — so confirmation
    # always originates from the human approver, never the model itself.
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

    it "does not advertise run_shell when chat_shell_enabled is false" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => false }))
      session = build(:chat_session, :workspace, account:, created_by: user, project:)

      names = described_class.chat_definitions_for(user: user, session: session).map { |definition| definition[:name] }

      expect(names).not_to include("run_shell")
    end

    it "advertises run_shell when chat_shell_enabled is true and user can run_agent?" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => true }))
      session = build(:chat_session, :workspace, account:, created_by: user, project:,
        clone_manifest: [ { project_id: project.id, path: "/workspace/repo-one" } ])

      names = described_class.chat_definitions_for(user: user, session: session).map { |definition| definition[:name] }

      expect(names).to include("run_shell")
    end

    it "does not advertise run_shell when user lacks run_agent? on the session project" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => true }))
      viewer = create(:user, :viewer, account:)
      session = build(:chat_session, :workspace, account:, created_by: viewer, project:,
        clone_manifest: [ { project_id: project.id, path: "/workspace/repo-one" } ])

      names = described_class.chat_definitions_for(user: viewer, session: session).map { |definition| definition[:name] }

      expect(names).not_to include("run_shell")
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

  describe ".dispatch_mcp" do
    let(:clone_manifest) do
      [ { project_id: 123, path: "/workspace/repo-one" } ]
    end

    def dispatch_git_status(session)
      described_class.dispatch_mcp(
        name: "git_status",
        arguments: { "repo_path" => "/workspace/repo-one" },
        user: user,
        session: session
      )
    end

    def stub_provision_ready(session, with_volume: false)
      allow(Containers::ProvisionForChat).to receive(:call) do
        updates = { container_capability: "ready", container_id: "container-123" }
        updates[:workspace_volume] = "paid-chat-workspace-#{session.id}" if with_volume
        session.update!(**updates)
      end
    end

    def stub_resource_release
      allow(Docker::Container).to receive(:get).and_return(
        instance_double(Docker::Container, stop: true, delete: true)
      )
      allow(Docker::Volume).to receive(:get).and_return(
        instance_double(Docker::Volume, remove: true)
      )
    end

    %w[pending provisioning failed].each do |capability|
      it "returns a structured unavailable result for container tools when #{capability}" do
        session = create(
          :chat_session,
          account: account,
          created_by: user,
          container_capability: capability,
          clone_manifest: clone_manifest
        )

        result = described_class.dispatch_mcp(
          name: "git_status",
          arguments: { "repo_path" => "/workspace/repo-one" },
          user: user,
          session: session
        )

        expect(result).to include(
          status: "error",
          error: "container_unavailable",
          container_capability: capability,
          message: Containers::CapabilityMessages.unavailable_for(capability)
        )
        expect(result[:retryable]).to eq(capability.in?(%w[pending provisioning]))
      end
    end

    %w[none stopped].each do |capability|
      it "lazily provisions container tools and replays the clone manifest when #{capability}" do
        session = create(:chat_session, account: account, created_by: user,
          container_capability: capability, clone_manifest: clone_manifest)
        stub_provision_ready(session)
        allow(ChatSessions::RestoreCloneManifest).to receive(:call)
        allow(described_class).to receive(:dispatch_via_registry).and_return({ status: "ok" })

        result = dispatch_git_status(session)

        expect(Containers::ProvisionForChat).to have_received(:call)
          .with(hash_including(chat_session: session, seed_project: false))
        expect(ChatSessions::RestoreCloneManifest).to have_received(:call).with(chat_session: session)
        expect(result).to eq(status: "ok")
      end
    end

    it "seeds the primary project instead of restoring when no manifest is recorded" do
      session = create(:chat_session, account: account, created_by: user, container_capability: "stopped")
      stub_provision_ready(session)
      allow(ChatSessions::RestoreCloneManifest).to receive(:call)
      allow(described_class).to receive(:dispatch_via_registry).and_return({ status: "ok" })

      dispatch_git_status(session)

      expect(Containers::ProvisionForChat).to have_received(:call)
        .with(hash_including(chat_session: session, seed_project: true))
      expect(ChatSessions::RestoreCloneManifest).not_to have_received(:call)
    end

    it "returns the session to stopped and surfaces a failure when manifest restore fails" do
      session = create(:chat_session, account: account, created_by: user,
                                       container_capability: "stopped", clone_manifest: clone_manifest)
      stub_provision_ready(session, with_volume: true)
      allow(ChatSessions::RestoreCloneManifest).to receive(:call)
        .and_raise("Workspace reset failed: permission denied")
      stub_resource_release

      result = dispatch_git_status(session)

      expect(session.reload.container_capability).to eq("stopped")
      expect(session.container_id).to be_nil
      expect(session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")).to be_present
      expect(result).to include(status: "error", error: "container_unavailable", container_capability: "stopped")
    end

    it "does not provision when a concurrent request already won the transition" do
      session = create(:chat_session, account: account, created_by: user,
                                       container_capability: "stopped", clone_manifest: clone_manifest)
      # Lost race: another request moved the session to pending and won the
      # transition, so this request must await instead of racing ProvisionForChat.
      allow(session).to receive(:request_container_provision!) do
        session.update!(container_capability: "pending")
        false
      end
      allow(Containers::ProvisionForChat).to receive(:call)

      result = described_class.dispatch_mcp(name: "git_status",
                                            arguments: { "repo_path" => "/workspace/repo-one" },
                                            user: user, session: session)

      expect(Containers::ProvisionForChat).not_to have_received(:call)
      expect(result).to include(status: "error", error: "container_unavailable",
                                container_capability: "pending", retryable: true)
    end

    it "dispatches normally when the container is ready" do
      session = create(
        :chat_session,
        :workspace,
        account: account,
        created_by: user,
        clone_manifest: clone_manifest
      )
      allow(described_class).to receive(:dispatch_via_registry).and_return({ status: "ok" })

      described_class.dispatch_mcp(
        name: "git_status",
        arguments: { "repo_path" => "/workspace/repo-one" },
        user: user,
        session: session
      )

      expect(described_class).to have_received(:dispatch_via_registry)
    end

    it "still raises for unknown tools on the MCP surface" do
      session = create(:chat_session, account: account, created_by: user)

      expect {
        described_class.dispatch_mcp(
          name: "nonexistent",
          arguments: {},
          user: user,
          session: session
        )
      }.to raise_error(ArgumentError, /Unknown tool/)
    end

    context "with operator tools" do
      let(:account) { create(:account) }
      let(:user) { create(:user, :owner, account:) }
      let(:session) { build(:chat_session, account:, created_by: user) }

      around do |example|
        original_emails = ENV["PAID_OPERATOR_EMAILS"]
        ENV["PAID_OPERATOR_EMAILS"] = user.email
        example.run
      ensure
        ENV["PAID_OPERATOR_EMAILS"] = original_emails
      end

      it "allows direct calls to operator read-only tools" do
        create(:account)

        result = described_class.dispatch_mcp(
          name: "operator_list_accounts",
          arguments: {},
          user: user,
          session: session
        )

        expect(result).to be_an(Array)
      end

      it "rejects direct calls to operator write tools" do
        expect {
          described_class.dispatch_mcp(
            name: "operator_suspend_account",
            arguments: { account_id: account.id, confirmed: true },
            user: user,
            session: session
          )
        }.to raise_error(ArgumentError, "Unknown tool: operator_suspend_account")
      end
    end
  end

  describe "write-operation audit" do
    it "flags the known write tools" do
      flagged_write_tool_names = described_class.all.select(&:write_operation?).map(&:tool_name)

      expect(flagged_write_tool_names).to match_array(write_tool_names)
    end
  end
end
