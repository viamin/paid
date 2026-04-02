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

      # Get the SHA of the default branch to base the feature branch on
      base_ref = client.ref(repo, "heads/#{default_branch}")
      base_sha = base_ref.object.sha

      # Create the feature branch
      client.create_ref(repo, "refs/heads/#{feature_branch}", base_sha)

      logger.info(
        message: "aggregate_branches.feature_branch_created",
        project_id: project.id,
        feature_branch: feature_branch,
        base_sha: base_sha
      )

      # Collect branches from successful sub-task runs
      merged_branches = []
      failed_merges = []

      results.each do |result|
        next unless result[:success]

        agent_run = AgentRun.find_by(id: result[:agent_run_id])
        next unless agent_run&.branch_name.present?

        branch_name = agent_run.branch_name

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
        rescue GithubClient::Error => e
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

      {
        feature_branch: feature_branch,
        merged_branches: merged_branches,
        failed_merges: failed_merges
      }
    end
  end
end
