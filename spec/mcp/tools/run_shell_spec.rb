# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RunShell do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: user, project:, clone_manifest: [
      { project_id: project.id, path: repo.fetch(:repo_path) }
    ])
  end
  let(:tool) { described_class.new(user:, session:) }
  let(:workspace_root) { make_workspace_root }
  let(:repo) do
    clone_repo_into_workspace(
      workspace_root:,
      repo_name: "repo-one",
      files: { "README.md" => "# Repo One\n", "script.sh" => "#!/bin/sh\necho hello" }
    )
  end

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo[:source_path]) if repo
  end

  before do
    create(:project_membership, :member, user:, project:)
    account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge(
      "chat_settings" => { "chat_shell_enabled" => true }
    ))
  end

  describe "self.available_for_chat?" do
    it "returns true when tenant setting is enabled, container is ready, and user can run_agent?" do
      expect(described_class.available_for_chat?(user:, session:)).to be true
    end

    it "returns false when tenant setting is disabled" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => false }))
      expect(described_class.available_for_chat?(user:, session:)).to be false
    end

    it "returns false when container is not ready" do
      session.update!(container_id: nil)
      expect(described_class.available_for_chat?(user:, session:)).to be false
    end

    it "returns false when user lacks run_agent? on the session project" do
      viewer = create(:user, :viewer, account:)
      expect(described_class.available_for_chat?(user: viewer, session:)).to be false
    end

    it "returns false when session has no project" do
      session.update!(project: nil)
      expect(described_class.available_for_chat?(user:, session:)).to be false
    end

    it "returns false for nil user" do
      expect(described_class.available_for_chat?(user: nil, session:)).to be false
    end
  end

  describe "self.available_to?" do
    it "returns false (tool is chat-only)" do
      expect(described_class.available_to?(user:)).to be false
    end
  end

  describe "#perform" do
    it "executes a shell command and returns stdout, stderr, and exit code" do
      result = tool.call(
        command: "echo hello",
        confirmed: true
      )

      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "rejects invocation when tenant setting is disabled at call time" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => false }))

      expect { tool.call(command: "echo hi", confirmed: true) }.to raise_error(ArgumentError, /not enabled/)
    end

    it "requires confirmed=true" do
      expect { tool.call(command: "echo hi") }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "rejects empty command" do
      expect { tool.call(command: "", confirmed: true) }.to raise_error(ArgumentError, /non-empty/)
    end

    it "rejects whitespace-only command" do
      expect { tool.call(command: "   ", confirmed: true) }.to raise_error(ArgumentError, /non-empty/)
    end

    it "rejects working directory outside clone manifest" do
      expect {
        tool.call(command: "echo hi", working_dir: "/workspace/not-a-repo", confirmed: true)
      }.to raise_error(ArgumentError, /must be under a cloned repo path/)
    end

    it "accepts working directory under a cloned repo" do
      result = tool.call(
        command: "pwd",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:exit_code]).to eq(0)
    end

    it "records an audit event on invocation" do
      expect {
        tool.call(command: "echo audited", confirmed: true)
      }.to change(AccountActivityEvent, :count).by(1)

      event = AccountActivityEvent.last
      expect(event.action).to eq("run_shell.executed")
      expect(event.actor).to eq(user)
      expect(event.metadata["command"]).to eq("echo audited")
    end

    it "returns non-zero exit code for failing commands" do
      result = tool.call(
        command: "exit 42",
        confirmed: true
      )

      expect(result[:exit_code]).to eq(42)
    end
  end
end
