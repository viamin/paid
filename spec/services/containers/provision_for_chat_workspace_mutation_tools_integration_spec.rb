# frozen_string_literal: true

require "rails_helper"
require "shellwords"

# Integration test that exercises the full chat workspace provisioning flow:
#   1. Containers::ProvisionForChat provisions a container and clones the
#      project's repo into the workspace volume, persisting a manifest entry.
#   2. Workspace mutation tools (write_repo_file, apply_patch, git_*) consume
#      that manifest entry via session.clone_manifest_entries to authorize.
#
# This catches regressions where the provisioning flow and the mutation tools
# drift apart — e.g. a new clone path that fails to record a manifest entry
# would silently break every workspace mutation tool even though their unit
# specs pass.
RSpec.describe Containers::ProvisionForChat do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:source_repo_path) { Dir.mktmpdir("chat-provision-source") }
  let(:workspace_root) { Dir.mktmpdir("chat-provision-workspace") }
  let(:chat_session) { create(:chat_session, :with_project, account:, project:) }

  # Local backend that runs the real workspace tool commands against a tmpdir
  # while short-circuiting the git clone step to copy from a local source repo.
  let(:backend) do
    Class.new do
      attr_reader :exec_calls

      def initialize(workspace_root:, source_repo_path:)
        @workspace_root = workspace_root
        @source_repo_path = source_repo_path
        @exec_calls = []
      end

      def get_container(_id)
        fake_container_class.new(@workspace_root)
      end

      def create_volume(_name, _opts); end

      def get_volume(name)
        fake_volume_class.new(name)
      end

      def delete_volume(_volume); end

      def create_container(_config)
        fake_container_class.new(@workspace_root)
      end

      def start_container(_container); end

      def stop_container(_container, **_opts); end

      def delete_container(_container, **_opts); end

      def exec_in_container(container, command, **options)
        @exec_calls << { container:, command:, options: }

        env = Array(options[:Env]).each_with_object({}) do |entry, memo|
          key, value = entry.split("=", 2)
          memo[key] = value
        end

        translated = translate(command, container.root)
        stdout, stderr, status = Open3.capture3(env, *translated)
        [ stdout.lines, stderr.lines, status.exitstatus ]
      end

      private

      def fake_container_class
        @fake_container_class ||= Class.new do
          def initialize(root)
            @root = root
          end

          attr_reader :root
          def id = "fake-container-id"
          def refresh! = self
          def info = { "State" => { "Running" => true } }
        end
      end

      def fake_volume_class
        @fake_volume_class ||= Class.new do
          def initialize(name)
            @name = name
          end

          attr_reader :name
        end
      end

      def translate(command, workspace_root)
        return command unless command.first == "sh" && command.length == 3

        script = command.last
        # Intercept the git clone call used by ProvisionForChat#seed_workspace!
        # and replace it with a local clone from the source fixture.
        # CodeQL: match `github.com` as a URL host (between `://` and the next `/`
        # or `:port` boundary), not as a free substring, so a redirect like
        # `attacker.com/github.com` cannot impersonate the upstream. The userinfo
        # class is permissive enough to allow `:` characters in the username
        # portion of URLs like `https://x-access-token:TOKEN@github.com/...`.
        if script.include?("git clone --depth 1") && script.match?(/:\/\/(?:[^\/?#]+@)?github\.com(?::[0-9]+)?(?:\/|$)/)
          local_script = "git clone #{Shellwords.escape(@source_repo_path)} . 2>&1"
          return [ "sh", "-c", "cd #{Shellwords.escape(workspace_root)} && #{local_script}" ]
        end

        rewritten = script.gsub("/workspace", workspace_root)
        [ "sh", "-c", "cd #{Shellwords.escape(workspace_root)} && #{rewritten}" ]
      end
    end.new(workspace_root:, source_repo_path:)
  end

  before do
    # Build a small source repo that mirrors what ProvisionForChat would clone
    # from GitHub in production: a single README on the default branch.
    run_cmd!("git", "-C", source_repo_path, "init", "-b", "main")
    run_cmd!("git", "-C", source_repo_path, "config", "user.name", "Spec Bot")
    run_cmd!("git", "-C", source_repo_path, "config", "user.email", "spec@example.test")
    File.write(File.join(source_repo_path, "README.md"), "# Provisioned Repo\n")
    run_cmd!("git", "-C", source_repo_path, "add", ".")
    run_cmd!("git", "-C", source_repo_path, "commit", "-m", "Initial commit")
  end

  around do |example|
    previous_backend = Rails.application.config.x.container_backend
    Rails.application.config.x.container_backend = backend
    example.run
  ensure
    Rails.application.config.x.container_backend = previous_backend
    FileUtils.rm_rf(source_repo_path)
    FileUtils.rm_rf(workspace_root)
  end

  it "provisions the workspace and writes a file via the mutation tool" do
    result = described_class.call(chat_session:, seed_project: true)
    expect(result).to be_success

    chat_session.reload
    expect(chat_session.container_id).to be_present
    expect(chat_session.clone_manifest_entries).to contain_exactly(
      a_hash_including(project_id: project.id, path: "/workspace")
    )

    write_result = Tools::WriteRepoFile.new(user:, session: chat_session).call(
      repo_path: "/workspace",
      path: "docs/new_file.md",
      content: "added by integration test\n",
      confirmed: true
    )

    expect(write_result[:status]).to include("?? docs/new_file.md")
    expect(File.read(File.join(workspace_root, "docs/new_file.md"))).to eq("added by integration test\n")
  end

  it "lets the mutation tool authorize against the manifest entry recorded by provisioning" do
    described_class.call(chat_session:, seed_project: true)

    chat_session.reload
    expect(chat_session.clone_manifest_entries).not_to be_empty

    # The mutation tool looks up the path in the manifest; if provisioning
    # forgot to record an entry, this raises ArgumentError "clone manifest".
    expect {
      Tools::GitStatus.new(user:, session: chat_session).call(repo_path: "/workspace")
    }.not_to raise_error
  end

  def run_cmd!(*command)
    stdout, stderr, status = Open3.capture3(*command)
    return stdout if status.success?

    raise "Command failed: #{command.join(' ')}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
  end
end
