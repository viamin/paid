# frozen_string_literal: true

require "open3"

# Manages git worktrees for isolated agent execution workspaces.
#
# Each project has a single bare clone shared across all agent runs.
# Individual worktrees provide independent working directories per agent.
#
# @example
#   service = WorktreeService.new(project)
#   service.ensure_cloned
#   worktree_path = service.create_worktree(agent_run)
#   # ... agent does work ...
#   service.push_branch(agent_run)
#   service.remove_worktree(agent_run)
class WorktreeService
  class Error < StandardError; end
  class CloneError < Error; end
  class WorktreeError < Error; end

  WORKSPACE_ROOT = ENV.fetch("WORKSPACE_ROOT", "/var/paid/workspaces")

  attr_reader :project

  def initialize(project)
    @project = project
    @mutex = Mutex.new
  end

  # Ensure we have an up-to-date clone of the repository.
  #
  # @return [String] Path to the bare repository
  def ensure_cloned
    repo_path = project_repo_path

    if File.exist?(File.join(repo_path, "HEAD"))
      fetch_latest
    else
      clone_repository
    end

    repo_path
  end

  # Create a new worktree for an agent run.
  #
  # @param agent_run [AgentRun] The agent run needing a workspace
  # @return [String] Path to the created worktree
  # @raise [WorktreeError] When worktree creation fails
  def create_worktree(agent_run)
    ensure_cloned

    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    suffix = SecureRandom.hex(3)
    worktree_name = "paid-agent-#{agent_run.id}-#{timestamp}-#{suffix}"
    worktree_path = File.join(worktrees_path, worktree_name)
    branch_name = "paid/#{worktree_name}"
    base_sha = current_commit_sha

    @mutex.synchronize do
      FileUtils.mkdir_p(worktrees_path)

      run_git(
        "worktree add -b #{branch_name} #{worktree_path} origin/#{project.default_branch}",
        chdir: project_repo_path
      )
    end

    agent_run.update!(
      worktree_path: worktree_path,
      branch_name: branch_name,
      base_commit_sha: base_sha
    )

    Worktree.create!(
      project: project,
      agent_run: agent_run,
      path: worktree_path,
      branch_name: branch_name,
      base_commit: base_sha,
      status: "active"
    )

    log_to_agent_run(agent_run, "Worktree created: #{worktree_name}")

    worktree_path
  rescue Error
    raise
  rescue => e
    raise WorktreeError, "Failed to create worktree: #{e.message}"
  end

  # Remove a worktree after agent run completes.
  #
  # @param agent_run [AgentRun] The agent run whose worktree to remove
  # @return [void]
  def remove_worktree(agent_run)
    worktree = agent_run.worktree
    return unless worktree&.active?
    return unless agent_run.worktree_path && Dir.exist?(agent_run.worktree_path)

    @mutex.synchronize do
      run_git(
        "worktree remove #{agent_run.worktree_path} --force",
        chdir: project_repo_path
      )

      unless worktree.pushed?
        run_git(
          "branch -D #{agent_run.branch_name}",
          chdir: project_repo_path,
          raise_on_error: false
        )
      end
    end

    worktree.mark_cleaned!
    log_to_agent_run(agent_run, "Worktree removed")
  rescue => e
    Rails.logger.warn(
      message: "worktree_service.remove_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
    worktree&.mark_cleanup_failed!
  end

  # Get the current commit SHA of the default branch.
  #
  # @return [String] The 40-character SHA
  def current_commit_sha
    run_git(
      "rev-parse origin/#{project.default_branch}",
      chdir: project_repo_path
    ).strip
  end

  # Push an agent run's branch to the remote.
  #
  # @param agent_run [AgentRun] The agent run whose branch to push
  # @return [String] The result commit SHA
  def push_branch(agent_run)
    run_git(
      "push origin #{agent_run.branch_name}",
      chdir: agent_run.worktree_path
    )

    result_sha = run_git("rev-parse HEAD", chdir: agent_run.worktree_path).strip
    agent_run.update!(result_commit_sha: result_sha)

    worktree = agent_run.worktree
    worktree&.mark_pushed!

    result_sha
  end

  # Clean up stale worktrees older than the given threshold.
  #
  # @param older_than [ActiveSupport::Duration] Age threshold (default 24 hours)
  # @return [void]
  def cleanup_stale_worktrees(older_than: 24.hours)
    return unless Dir.exist?(worktrees_path)

    Dir.glob(File.join(worktrees_path, "paid-agent-*")).each do |path|
      next unless File.directory?(path)
      next unless File.mtime(path) < older_than.ago

      run_git(
        "worktree remove #{path} --force",
        chdir: project_repo_path,
        raise_on_error: false
      )
    end

    run_git("worktree prune", chdir: project_repo_path, raise_on_error: false)
  end

  private

  def project_repo_path
    File.join(WORKSPACE_ROOT, project.account_id.to_s, project.id.to_s, "repo")
  end

  def worktrees_path
    File.join(WORKSPACE_ROOT, project.account_id.to_s, project.id.to_s, "worktrees")
  end

  def clone_repository
    FileUtils.mkdir_p(File.dirname(project_repo_path))

    clone_url = authenticated_clone_url
    run_git("clone --bare #{clone_url} #{project_repo_path}")

    project.github_token.touch_last_used!
  rescue Error
    raise
  rescue => e
    raise CloneError, "Failed to clone repository: #{e.message}"
  end

  def fetch_latest
    remote_url = authenticated_clone_url
    run_git("remote set-url origin #{remote_url}", chdir: project_repo_path, raise_on_error: false)
    run_git("fetch --all --prune", chdir: project_repo_path)

    project.github_token.touch_last_used!
  end

  def authenticated_clone_url
    "https://x-access-token:#{project.github_token.token}@github.com/#{project.full_name}.git"
  end

  def run_git(command, chdir: nil, raise_on_error: true)
    options = {}
    options[:chdir] = chdir if chdir

    stdout, stderr, status = Open3.capture3("git #{command}", **options)

    if !status.success? && raise_on_error
      raise Error, "Git command failed: #{command}\n#{stderr}"
    end

    stdout
  end

  def log_to_agent_run(agent_run, message)
    agent_run.log!("system", message)
  rescue => e
    Rails.logger.warn(
      message: "worktree_service.log_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end
end
