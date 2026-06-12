# frozen_string_literal: true

require "rails_helper"
require "open3"
require "ostruct"

RSpec.describe ProjectConventions::OpenHookGuardrailPullRequest do
  let(:tmpdir) { Pathname(Dir.mktmpdir) }
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }
  let(:worktree_service) { instance_double(WorktreeService) }
  let(:pull_request) { OpenStruct.new(html_url: "https://github.com/acme/widgets/pull/42") }
  let(:allowed_types) { %w[feat fix] }

  around do |example|
    example.run
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  before do
    allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:create_pull_request).and_return(pull_request)
  end

  it "opens a PR that installs Husky-backed commit-msg validation" do
    repo_path = create_repo!(
      ".husky/pre-commit" => "#!/bin/sh\n",
      ".commitlintrc.json" => '{"rules":{"type-enum":[2,"always",["feat","fix"]]}}'
    )
    recommendation = build_recommendation("husky", ".husky/commit-msg")

    stub_worktree(repo_path)

    result = described_class.call(project: project, recommendation: recommendation)

    expect(result.pull_request_url).to eq("https://github.com/acme/widgets/pull/42")
    expect(repo_path.join(".husky/commit-msg").read).to include('"$repo_root/.paid/hooks/validate-commit-msg" "$1"')
    expect(repo_path.join(".paid/hooks/validate-commit-msg").read).to include("Allowed types: feat, fix")
    expect(repo_path.join(".paid/hooks/validate-commit-msg")).to be_executable
    expect(github_client).to have_received(:create_pull_request).with(
      project.full_name,
      base: project.default_branch,
      head: a_string_starting_with("paid/hook-guardrails-"),
      title: "chore: install repo-managed commit-msg guardrail",
      body: include("Hook manager: husky")
    )
  end

  it "preserves the Husky legacy preamble when the repo uses husky.sh" do
    repo_path = create_repo!(
      ".husky/pre-commit" => "#!/bin/sh\n",
      ".husky/_/husky.sh" => "#!/bin/sh\n",
      ".commitlintrc.json" => '{"rules":{"type-enum":[2,"always",["feat","fix"]]}}'
    )
    recommendation = build_recommendation("husky", ".husky/commit-msg", husky_legacy: true)

    stub_worktree(repo_path)

    described_class.call(project: project, recommendation: recommendation)

    expect(repo_path.join(".husky/commit-msg").read).to include('. "$(dirname -- "$0")/_/husky.sh"')
  end

  it "omits the legacy Husky preamble for current Husky repos" do
    repo_path = create_repo!(
      ".husky/pre-commit" => "#!/bin/sh\n",
      ".commitlintrc.json" => '{"rules":{"type-enum":[2,"always",["feat","fix"]]}}'
    )
    recommendation = build_recommendation("husky", ".husky/commit-msg", husky_legacy: false)

    stub_worktree(repo_path)

    described_class.call(project: project, recommendation: recommendation)

    expect(repo_path.join(".husky/commit-msg").read).not_to include("husky.sh")
  end

  it "updates lefthook.yml instead of writing a raw Git hook" do
    repo_path = create_repo!(
      "lefthook.yml" => "pre-commit:\n  commands:\n    lint:\n      run: bin/lint\n"
    )
    recommendation = build_recommendation("lefthook", "lefthook.yml")

    stub_worktree(repo_path)

    described_class.call(project: project, recommendation: recommendation)

    config = YAML.safe_load(repo_path.join("lefthook.yml").read)
    expect(config.dig("commit-msg", "commands", "paid-conventional-commits", "run"))
      .to eq(".paid/hooks/validate-commit-msg {1}")
    expect(repo_path.join(".githooks/commit-msg")).not_to exist
  end

  def stub_worktree(repo_path)
    allow(worktree_service).to receive(:with_temporary_worktree).with(project.default_branch).and_yield(repo_path.to_s)
    allow(worktree_service).to receive(:run_worktree_command) do |worktree_path, *args|
      stdout, stderr, status = Open3.capture3("git", *args, chdir: worktree_path)
      raise WorktreeService::Error, stderr unless status.success?

      stdout
    end
  end

  def build_recommendation(manager_type, hook_path, husky_legacy: nil)
    create(:project_convention_recommendation,
           project: project,
           action_type: "open_pr",
           evidence: {
             "strategy" => {
               "manager_type" => manager_type,
               "hook_path" => hook_path,
               "husky_legacy" => husky_legacy,
               "validator_path" => ".paid/hooks/validate-commit-msg",
               "allowed_types" => allowed_types
             }
           })
  end

  def create_repo!(files)
    origin_path = tmpdir.join("origin.git")
    repo_path = tmpdir.join("repo")

    Open3.capture3("git", "init", "--bare", origin_path.to_s)
    Open3.capture3("git", "clone", origin_path.to_s, repo_path.to_s)
    Open3.capture3("git", "config", "user.name", "Spec User", chdir: repo_path.to_s)
    Open3.capture3("git", "config", "user.email", "spec@example.com", chdir: repo_path.to_s)
    # Keep commits hermetic: never inherit host/global signing config (e.g. a
    # gpg.ssh.program pointing at a binary that does not exist in this environment).
    Open3.capture3("git", "config", "commit.gpgsign", "false", chdir: repo_path.to_s)

    files.each do |relative_path, content|
      path = repo_path.join(relative_path)
      path.dirname.mkpath
      path.write(content)
      FileUtils.chmod(0o755, path) if relative_path.start_with?(".husky/")
    end

    Open3.capture3("git", "add", "--all", chdir: repo_path.to_s)
    Open3.capture3("git", "commit", "-m", "chore: seed repo", chdir: repo_path.to_s)
    Open3.capture3("git", "branch", "-M", "main", chdir: repo_path.to_s)
    Open3.capture3("git", "push", "-u", "origin", "main", chdir: repo_path.to_s)

    repo_path
  end
end
