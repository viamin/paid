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

      ids_to_resolve = unresolved.map { |t| t[:id] }
      result = client.resolve_review_threads_batch(ids_to_resolve)

      resolved_count = result[:resolved].size
      failed_count = result[:failed].size

      result[:failed].each do |failure|
        logger.warn(
          message: "agent_execution.resolve_thread_failed",
          agent_run_id: agent_run_id,
          thread_id: failure[:id],
          error: failure[:error]
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
