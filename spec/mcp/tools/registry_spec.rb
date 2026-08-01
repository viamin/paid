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

    {
      "none" => false,
      "pending" => false,
      "provisioning" => false,
      "ready" => true,
      "failed" => false,
      "stopped" => false
    }.each do |capability, visible|
      it "filters container tools for #{capability}" do
        session = create(
          :chat_session,
          account: account,
          created_by: user,
          container_capability: capability,
          clone_manifest: clone_manifest,
          container_id: (visible ? "container-123" : nil)
        )

        tool_names = described_class.tools_for(session:, user:).map(&:tool_name)

        expect(tool_names).to include("list_projects")
        expect(tool_names.include?("git_status")).to eq(visible)
        expect(tool_names.include?("git_diff")).to eq(visible)
        expect(tool_names.include?("write_repo_file")).to eq(visible)
      end
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
end
