# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::CloneProject do
  # @spec clone_project returns already_cloned for manifest entries even when the session is at capacity.
  # @spec clone_project uses the resolved project GitHub credential, including GitHub App tokens, for clones.
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, :workspace, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }

  before do
    # Mock the container backend to return success for clone operations
    backend = instance_double(Containers::Backends::Base, remote?: false)
    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive_messages(
      get_container: instance_double(Docker::Container, id: session.container_id),
      exec_in_container: [ [], [], 0 ],
      delete_container: nil
    )
  end

  def stub_repo_read_client(credential:, identity:)
    allow(Tools::RepoReadClientResolver).to receive(:new).and_return(
      instance_double(
        Tools::RepoReadClientResolver,
        resolve: Tools::RepoReadClientResolver::ResolvedClient.new(
          client: instance_double(GithubClient),
          identity:,
          credential:
        )
      )
    )
  end

  describe "#perform" do
    it "clones a project successfully" do
      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:status]).to eq("cloned")
      expect(result[:project_id]).to eq(project.id)
      expect(result[:project_slug]).to eq(project.full_name.tr("/", "-"))
      expect(result[:repo_path]).to eq("/workspace/#{project.full_name.tr('/', '-')}")
      expect(result[:token_identity]).to be_present
      expect(result[:cloned_at]).to be_present
    end

    it "records a manifest entry on successful clone" do
      tool.call(project_id: project.id, confirmed: true)

      session.reload
      expect(session.clone_manifest.size).to eq(1)
      entry = session.clone_manifest.first
      expect(entry.project_id).to eq(project.id)
      expect(entry.token_identity).to be_present
      expect(entry.cloned_at).to be_present
    end

    it "passes the clone token as an ephemeral env var" do
      tool.call(project_id: project.id, confirmed: true)

      expect(Containers.backend).to have_received(:exec_in_container) do |_container, _cmd, **opts|
        env = opts[:Env]
        expect(env).to be_present
        token_entry = env.find { |e| e.start_with?("CLONE_TOKEN=") }
        expect(token_entry).to be_present
      end
    end

    it "builds the clone command with an expandable $CLONE_TOKEN placeholder" do
      tool.call(project_id: project.id, confirmed: true)

      expect(Containers.backend).to have_received(:exec_in_container) do |_container, command, **_opts|
        script = command.last
        # The placeholder must reach the shell unescaped so it expands from the
        # Env entry; `\$CLONE_TOKEN` would authenticate with the literal string.
        expect(script).to include("x-access-token:$CLONE_TOKEN@github.com")
        expect(script).not_to include("x-access-token:\\$CLONE_TOKEN")
        # The user/org-controlled repo path is still escaped.
        expect(script).to include("git clone --depth 1")
      end
    end

    it "redacts the clone token from a failed clone's error output" do
      secret = "ghp_supersecrettoken123"
      stub_repo_read_client(credential: secret, identity: "project-token:#{project.github_token.name}")

      leak = "fatal: repository 'https://x-access-token:#{secret}@github.com/#{project.full_name}.git/' not found"
      allow(Containers.backend).to receive(:exec_in_container).and_return([ [], [ leak ], 128 ])

      expect {
        tool.call(project_id: project.id, confirmed: true)
      }.to raise_error do |error|
        expect(error).to be_a(ArgumentError)
        expect(error.message).to include("Clone failed (exit 128)")
        expect(error.message).not_to include(secret)
        expect(error.message).to include("x-access-token:[REDACTED]@github.com")
      end
    end

    it "surfaces token identity in the result" do
      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:token_identity]).to match(/\A(project-token:|user-token:|github-app:)/)
    end

    it "returns already_cloned status for an existing clone" do
      # First clone
      tool.call(project_id: project.id, confirmed: true)

      # Second clone of same project
      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:status]).to eq("already_cloned")
      expect(result[:project_id]).to eq(project.id)
      expect(result[:token_identity]).to be_present
    end

    it "returns already_cloned when the manifest is already at the clone limit" do
      tenant_setting = create(:tenant_setting, account:)
      allow(account).to receive(:tenant_setting).and_return(tenant_setting)
      allow(tenant_setting).to receive(:chat_max_cloned_repos).and_return(1)
      session.append_clone_manifest_entry(
        project_id: project.id,
        cloned_at: Time.current,
        path: "/workspace/#{project.full_name.tr('/', '-')}",
        token_identity: "project-token:#{project.github_token.name}"
      )
      session.save!

      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:status]).to eq("already_cloned")
      expect(result[:project_id]).to eq(project.id)
    end

    it "rejects unconfirmed operations" do
      expect {
        tool.call(project_id: project.id, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "rejects when confirmation is missing" do
      expect {
        tool.call(project_id: project.id)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "rejects unauthorized projects" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)

      expect {
        tool.call(project_id: other_project.id, confirmed: true)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "rejects when no GitHub token is available" do
      # Create a project with an inactive token
      project.github_token.update!(revoked_at: 1.day.ago)

      expect {
        tool.call(project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, /no active GitHub token/)
    end

    it "rejects when GitHub token is expired" do
      project.github_token.update!(expires_at: 1.day.ago)

      expect {
        tool.call(project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, /no active GitHub token/)
    end

    it "enforces max_cloned_repos limit" do
      stub_const("Tools::CloneProject::CLONE_TIMEOUT", 120)

      # Fill the manifest to 1 below the default limit of 5
      4.times do |i|
        entry_project = create(:project, account:)
        session.append_clone_manifest_entry(
          project_id: entry_project.id,
          cloned_at: Time.current,
          path: "/workspace/project-#{i}",
          token_identity: "project-token:token-#{i}"
        )
      end
      session.save!

      # The 5th clone should succeed
      result = tool.call(project_id: project.id, confirmed: true)
      expect(result[:status]).to eq("cloned")

      # The 6th clone should fail
      sixth_project = create(:project, account:)
      expect {
        tool.call(project_id: sixth_project.id, confirmed: true)
      }.to raise_error(ArgumentError, /Maximum cloned repos limit reached/)
    end

    it "uses the project GitHub App credential for app-backed projects" do
      project = create(:project, :with_github_installation, account:)
      tool = described_class.new(user:, session:)

      stub_repo_read_client(
        credential: "ghs_app_token",
        identity: "github-app:#{project.github_installation.github_installation_id}"
      )

      result = tool.call(project_id: project.id, confirmed: true)

      expect(result[:status]).to eq("cloned")
      expect(result[:token_identity]).to eq("github-app:#{project.github_installation.github_installation_id}")
      expect(Containers.backend).to have_received(:exec_in_container) do |_container, _cmd, **opts|
        expect(opts.fetch(:Env)).to include("CLONE_TOKEN=ghs_app_token")
      end
    end

    it "uses per-account max_cloned_repos setting" do
      tenant_setting = create(:tenant_setting, account:)
      allow(tenant_setting).to receive(:chat_max_cloned_repos).and_return(2)
      allow(account).to receive(:tenant_setting).and_return(tenant_setting)

      # Fill to 1
      entry_project = create(:project, account:)
      session.append_clone_manifest_entry(
        project_id: entry_project.id,
        cloned_at: Time.current,
        path: "/workspace/other",
        token_identity: "project-token:other"
      )
      session.save!

      # Second clone should succeed
      result = tool.call(project_id: project.id, confirmed: true)
      expect(result[:status]).to eq("cloned")

      # Third should fail
      third_project = create(:project, account:)
      expect {
        tool.call(project_id: third_project.id, confirmed: true)
      }.to raise_error(ArgumentError, /Maximum cloned repos limit reached \(2\)/)
    end

    it "rejects when container is not available" do
      session.update!(container_capability: "none", container_id: nil)
      tool_no_container = described_class.new(user:, session:)

      expect {
        tool_no_container.call(project_id: project.id, confirmed: true)
      }.to raise_error(ArgumentError, /running workspace container/)
    end
  end

  describe "class methods" do
    it "requires a container" do
      expect(described_class.requires_container?).to be(true)
    end

    it "is a write operation" do
      expect(described_class.write_operation?).to be(true)
    end

    it "is not available to non-chat contexts" do
      expect(described_class.available_to?(user:)).to be(false)
    end

    it "is available for chat when container is ready" do
      expect(described_class.available_for_chat?(user:, session:)).to be(true)
    end

    it "is not available for chat when container is not ready" do
      no_container_session = create(:chat_session, account:, created_by: user)
      expect(described_class.available_for_chat?(user:, session: no_container_session)).to be(false)
    end

    it "is not available for chat when user is nil" do
      expect(described_class.available_for_chat?(user: nil, session:)).to be(false)
    end
  end
end
