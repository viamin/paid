# frozen_string_literal: true

module Activities
  # Resolves unresolved review threads on a pull request after the agent
  # has pushed its changes. When thread_ids are provided, only those
  # prompt-captured unresolved threads are eligible for auto-resolution.
  #
  # Individual thread resolution failures are logged but do not fail the
  # activity — this is a best-effort cleanup step.
  class ResolveReviewThreadsActivity < BaseActivity
    activity_name "ResolveReviewThreads"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      thread_ids = Array(input[:thread_ids]).compact
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project
      client = project.github_token.client

      threads = client.review_threads(project.full_name, agent_run.source_pull_request_number)
      unresolved = threads.reject { |t| t[:is_resolved] }
      unresolved.select! { |thread| thread_ids.include?(thread[:id]) } if thread_ids.any?

      resolved_count = 0
      failed_count = 0

      unresolved.each do |thread|
        client.resolve_review_thread(thread[:id])
        resolved_count += 1
      rescue GithubClient::Error => e
        failed_count += 1
        logger.warn(
          message: "agent_execution.resolve_thread_failed",
          agent_run_id: agent_run_id,
          thread_id: thread[:id],
          error: e.message
        )
      end

      logger.info(
        message: "agent_execution.resolve_review_threads",
        agent_run_id: agent_run_id,
        requested_thread_ids: thread_ids,
        resolved_count: resolved_count,
        failed_count: failed_count
      )

      {
        agent_run_id: agent_run_id,
        requested_thread_ids: thread_ids,
        resolved_count: resolved_count,
        failed_count: failed_count
      }
    end
  end
end
