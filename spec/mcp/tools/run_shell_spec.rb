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
    FileUtils.rm_rf(repo_two[:source_path]) if defined?(repo_two) && repo_two
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

    it "returns false when the session has no cloned repos" do
      session.update!(clone_manifest: [])
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
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "rejects invocation when tenant setting is disabled at call time" do
      account.tenant_setting!.update!(features: account.tenant_setting!.features.deep_merge("chat_settings" => { "chat_shell_enabled" => false }))

      expect { tool.call(command: "echo hi", working_dir: repo.fetch(:repo_path), confirmed: true) }.to raise_error(ArgumentError, /not enabled/)
    end

    it "requires confirmed=true" do
      expect {
        tool.call(command: "echo hi", working_dir: repo.fetch(:repo_path))
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "rejects empty command" do
      expect { tool.call(command: "", working_dir: repo.fetch(:repo_path), confirmed: true) }.to raise_error(ArgumentError, /non-empty/)
    end

    it "rejects whitespace-only command" do
      expect { tool.call(command: "   ", working_dir: repo.fetch(:repo_path), confirmed: true) }.to raise_error(ArgumentError, /non-empty/)
    end

    it "requires a working directory" do
      expect {
        tool.call(command: "echo hi", confirmed: true)
      }.to raise_error(ArgumentError, /working_dir must be provided/)
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

    it "resolves the requested working directory once during clone-manifest validation" do
      working_dir = File.join(repo.fetch(:repo_path), "lib")

      allow(tool).to receive(:normalize_workspace_path).with(working_dir).and_return(working_dir)
      allow(tool).to receive(:resolve_container_path).and_call_original

      tool.send(:validate_working_dir!, working_dir)

      expect(tool).to have_received(:resolve_container_path).with(working_dir).once
    end

    it "records an audit event attributed to the repo the command ran in" do
      expect {
        tool.call(command: "echo audited", working_dir: repo.fetch(:repo_path), confirmed: true)
      }.to change(AccountActivityEvent, :count).by(1)

      event = AccountActivityEvent.last
      expect(event.action).to eq("run_shell.executed")
      expect(event.actor).to eq(user)
      expect(event.metadata["command"]).to eq("echo audited")
      expect(event.metadata["project_id"]).to eq(project.id)
    end

    it "returns non-zero exit code for failing commands" do
      result = tool.call(
        command: "exit 42",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:exit_code]).to eq(42)
    end
  end

  context "when the session clones multiple repos" do
    let(:project_two) { create(:project, account:) }
    let!(:repo_two) do
      clone_repo_into_workspace(workspace_root:, repo_name: "repo-two", files: { "README.md" => "# Repo Two\n" })
    end
    # A viewer has no account-level run_agent?, so access is granted only where a
    # project membership exists (project, not project_two).
    let(:member) { create(:user, :viewer, account:) }
    let(:session) do
      create(:chat_session, :workspace, account:, created_by: member, project:, clone_manifest: [
        { project_id: project.id, path: repo.fetch(:repo_path) },
        { project_id: project_two.id, path: repo_two.fetch(:repo_path) }
      ])
    end

    before do
      create(:project_membership, :member, user: member, project:)
    end

    # A shell command is not sandboxed to its working directory (the command body
    # can `cd` anywhere in the container), so run_shell grants workspace-scoped
    # access: it requires run_agent? on every cloned repo in the session, not
    # just the one named in working_dir.
    it "denies shell for any working directory when any cloned repo is not run_agent?-authorized for the user" do
      expect {
        described_class.new(user: member, session:).call(
          command: "pwd",
          working_dir: repo.fetch(:repo_path),
          confirmed: true
        )
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "denies shell entirely (self.available_for_chat?) when any cloned repo is not run_agent?-authorized for the user" do
      expect(described_class.available_for_chat?(user: member, session:)).to be false
    end

    context "when the user can run_agent? on every cloned repo" do
      before do
        create(:project_membership, :member, user: member, project: project_two)
      end

      it "runs shell against the requested working directory" do
        result = described_class.new(user: member, session:).call(
          command: "pwd",
          working_dir: repo.fetch(:repo_path),
          confirmed: true
        )

        expect(result[:exit_code]).to eq(0)
      end

      it "attributes the audit event to the repo the command actually ran in" do
        described_class.new(user: member, session:).call(
          command: "echo multi",
          working_dir: repo_two.fetch(:repo_path),
          confirmed: true
        )

        expect(AccountActivityEvent.last.metadata["project_id"]).to eq(project_two.id)
      end
    end
  end

  describe "timeout handling" do
    def exec_call_options_for(command_fragment)
      backend = Rails.application.config.x.container_backend
      backend.exec_calls.find { |call| call[:command].last.include?(command_fragment) }.fetch(:options)
    end

    it "uses the default timeout when none is given" do
      tool.call(command: "echo default-timeout", working_dir: repo.fetch(:repo_path), confirmed: true)

      expect(exec_call_options_for("echo default-timeout")[:wait]).to eq(Tools::RunShell::DEFAULT_TIMEOUT)
    end

    it "uses the requested timeout when within bounds" do
      tool.call(command: "echo custom-timeout", working_dir: repo.fetch(:repo_path), timeout: 5, confirmed: true)

      expect(exec_call_options_for("echo custom-timeout")[:wait]).to eq(5)
    end

    it "clamps the requested timeout to MAX_TIMEOUT" do
      tool.call(command: "echo capped-timeout", working_dir: repo.fetch(:repo_path), timeout: 10_000, confirmed: true)

      expect(exec_call_options_for("echo capped-timeout")[:wait]).to eq(Tools::RunShell::MAX_TIMEOUT)
    end
  end

  describe "oversize output" do
    it "truncates stdout exceeding MAX_OUTPUT_BYTES and flags it" do
      result = tool.call(
        command: "head -c 150000 /dev/zero | tr '\\0' 'a'",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:stdout].bytesize).to be <= Tools::RunShell::MAX_OUTPUT_BYTES + 200
      expect(result[:stdout]).to include("[Output truncated at")
      expect(result[:stdout_truncated]).to be true
    end

    it "truncates stderr exceeding MAX_OUTPUT_BYTES and flags it" do
      result = tool.call(
        command: "head -c 150000 /dev/zero | tr '\\0' 'a' 1>&2",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:stderr].bytesize).to be <= Tools::RunShell::MAX_OUTPUT_BYTES + 200
      expect(result[:stderr]).to include("[Output truncated at")
      expect(result[:stderr_truncated]).to be true
    end

    it "does not flag output under MAX_OUTPUT_BYTES as truncated" do
      result = tool.call(command: "echo small", working_dir: repo.fetch(:repo_path), confirmed: true)

      expect(result).not_to have_key(:stdout_truncated)
      expect(result).not_to have_key(:stderr_truncated)
    end

    it "truncates on a valid UTF-8 boundary so the result serializes to JSON" do
      # 3-byte UTF-8 character (e.g. U+2603 SNOWMAN) repeated so the byte cutoff
      # at MAX_OUTPUT_BYTES is very likely to land mid-character.
      result = tool.call(
        command: "printf '\\xe2\\x98\\x83%.0s' $(seq 1 40000)",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:stdout_truncated]).to be true
      expect(result[:stdout].encoding).to eq(Encoding::UTF_8)
      expect(result[:stdout]).to be_valid_encoding
      expect { result.to_json }.not_to raise_error
    end
  end

  describe "output encoding" do
    it "normalizes non-UTF-8 command output so the result serializes to JSON" do
      result = tool.call(
        command: "printf '\\xff\\xfehello'",
        working_dir: repo.fetch(:repo_path),
        confirmed: true
      )

      expect(result[:stdout].encoding).to eq(Encoding::UTF_8)
      expect(result[:stdout]).to be_valid_encoding
      expect { result.to_json }.not_to raise_error
    end
  end
end
