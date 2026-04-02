# frozen_string_literal: true

module Activities
  # Aggregates completed sub-task branches into a single feature branch.
  #
  # Creates a new branch from the project's default branch and merges
  # each successful sub-task branch into it via the GitHub API.
  # Skips failed or branchless sub-tasks gracefully.
  #
  # Input:
  #   project_id: ID of the project
  #   parent_issue_id: ID of the parent feature issue (optional)
  #   results: Array of child workflow results with branch info
  #   feature_branch_name: Name for the aggregated feature branch
  #
  # Returns:
  #   feature_branch: Name of the created feature branch
  #   merged_branches: Array of branch names successfully merged
  #   failed_merges: Array of { branch:, error: } for merge failures
  class AggregateBranchesActivity < BaseActivity
    activity_name "AggregateBranches"

    def execute(input)
      project = Project.find(input[:project_id])
      results = input.fetch(:results, [])
      feature_branch = input[:feature_branch_name]

      client = project.github_token.client
      repo = project.full_name
      default_branch = project.default_branch

      # Preload agent runs for successful results to avoid N+1 queries
      successful_agent_run_ids = results
        .select { |result| result[:success] && result[:agent_run_id].present? }
        .map { |result| result[:agent_run_id] }
      agent_runs_by_id = AgentRun.where(id: successful_agent_run_ids).index_by(&:id)

      # Identify merge candidates before creating the branch to avoid orphan refs
      merge_candidates = results.filter_map do |result|
        next unless result[:success]

        agent_run = agent_runs_by_id[result[:agent_run_id]]
        agent_run&.branch_name.presence
      end

      if merge_candidates.empty?
        return {
          feature_branch: feature_branch,
          merged_branches: [],
          failed_merges: []
        }
      end

      # Get the SHA of the default branch to base the feature branch on
      base_ref = client.ref(repo, "heads/#{default_branch}")
      base_sha = base_ref.object.sha

      # Create the feature branch idempotently so retries don't fail
      create_feature_branch(client, repo, feature_branch, base_sha, project)

      logger.info(
        message: "aggregate_branches.feature_branch_created",
        project_id: project.id,
        feature_branch: feature_branch,
        base_sha: base_sha
      )

      merged_branches = []
      failed_merges = []

      merge_candidates.each do |branch_name|
        begin
          client.merge(repo, feature_branch, branch_name,
            commit_message: "Merge #{branch_name} into #{feature_branch}")
          merged_branches << branch_name

          logger.info(
            message: "aggregate_branches.branch_merged",
            project_id: project.id,
            feature_branch: feature_branch,
            source_branch: branch_name
          )
        rescue GithubClient::ApiError => e
          # Only treat merge conflicts (HTTP 409) as expected per-branch failures.
          # Re-raise auth errors, rate limits, and other API errors.
          raise unless e.status == 409

          failed_merges << { branch: branch_name, error: e.message }

          logger.warn(
            message: "aggregate_branches.merge_failed",
            project_id: project.id,
            feature_branch: feature_branch,
            source_branch: branch_name,
            error: e.message
          )
        end
      end

      # Clean up the feature branch if all merges failed
      if merged_branches.empty?
        delete_feature_branch(client, repo, feature_branch, project)
      end

      {
        feature_branch: feature_branch,
        merged_branches: merged_branches,
        failed_merges: failed_merges
      }
    end

    private

    def create_feature_branch(client, repo, feature_branch, base_sha, project)
      client.create_ref(repo, "refs/heads/#{feature_branch}", base_sha)
    rescue GithubClient::ApiError => e
      raise unless e.status == 422

      # Branch already exists (likely a retry). Verify it points to the expected SHA.
      existing_ref = client.ref(repo, "heads/#{feature_branch}")
      unless existing_ref.object.sha == base_sha
        raise
      end

      logger.info(
        message: "aggregate_branches.feature_branch_already_exists",
        project_id: project.id,
        feature_branch: feature_branch,
        base_sha: base_sha
      )
    end

    def delete_feature_branch(client, repo, feature_branch, project)
      client.delete_ref(repo, "heads/#{feature_branch}")

      logger.info(
        message: "aggregate_branches.feature_branch_deleted",
        project_id: project.id,
        feature_branch: feature_branch
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "aggregate_branches.feature_branch_delete_failed",
        project_id: project.id,
        feature_branch: feature_branch,
        error: e.message
      )
    end
  end
end
