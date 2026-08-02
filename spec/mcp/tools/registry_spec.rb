# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }

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
          expectedBehavior: "invoking_waits_for_inflight_provision"
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

  describe ".dispatch_mcp" do
    let(:clone_manifest) do
      [ { project_id: 123, path: "/workspace/repo-one" } ]
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
        stub_const("Tools::Registry::MCP_CONTAINER_WAIT_TIMEOUT", 0) if capability.in?(%w[pending provisioning])

        result = described_class.dispatch_mcp(
          name: "git_status",
          arguments: { "repo_path" => "/workspace/repo-one" },
          user: user,
          session: session
        )

        expect(result).to include(
          status: "error",
          error: "container_unavailable",
          container_capability: capability
        )
        expect(result[:retryable]).to eq(capability.in?(%w[pending provisioning]))
      end
    end

    %w[none stopped].each do |capability|
      it "lazily provisions container tools when #{capability}" do
        session = create(
          :chat_session,
          account: account,
          created_by: user,
          container_capability: capability,
          clone_manifest: clone_manifest
        )
        allow(Containers::ProvisionForChat).to receive(:call) do
          session.update!(container_capability: "ready", container_id: "container-123")
        end
        allow(described_class).to receive(:dispatch_via_registry).and_return({ status: "ok" })

        result = described_class.dispatch_mcp(
          name: "git_status",
          arguments: { "repo_path" => "/workspace/repo-one" },
          user: user,
          session: session
        )

        expect(Containers::ProvisionForChat).to have_received(:call).with(chat_session: session)
        expect(result).to eq(status: "ok")
      end
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
  end
end
