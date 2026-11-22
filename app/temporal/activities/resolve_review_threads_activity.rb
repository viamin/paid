# frozen_string_literal: true

module Activities
  # Resolves unresolved review threads on a pull request after the agent
  # has pushed its changes. When thread_ids are provided, only those
  # prompt-captured unresolved threads are eligible for auto-resolution.
  #
  # Individual thread resolution failures are logged but do not fail the
  # activity — this is a best-effort cleanup step.
  # @spec FOCUSED-RUN-011
  class ResolveReviewThreadsActivity < BaseActivity
    activity_name "ResolveReviewThreads"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      thread_ids = Array(input[:thread_ids]).filter_map { |id| id.to_s.presence }.uniq
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project
      client = project.client

      return stale_head_result(agent_run_id, thread_ids) unless expected_head_matches?(input, client, project, agent_run)

      threads = client.review_threads(project.full_name, agent_run.source_pull_request_number)
      return stale_threads_result(agent_run_id, thread_ids) unless expected_threads_match?(input, threads, thread_ids)

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

    private

    def expected_head_matches?(input, client, project, agent_run)
      expected_head_sha = input[:expected_head_sha]
      return true if expected_head_sha.blank? # Recorded pre-#5288 activity command.

      client.pull_request(project.full_name, agent_run.source_pull_request_number).head.sha.to_s == expected_head_sha
    end

    def stale_head_result(agent_run_id, thread_ids)
      logger.warn(message: "agent_execution.review_thread_resolution_stale_head", agent_run_id: agent_run_id,
        requested_thread_ids: thread_ids)
      { agent_run_id: agent_run_id, requested_thread_ids: thread_ids, resolved_count: 0, failed_count: 0, stale_head: true }
    end

    def expected_threads_match?(input, threads, thread_ids)
      return true if input[:expected_head_sha].blank? # Recorded pre-#5288 activity command.
      return false if thread_ids.empty?

      expected = input[:thread_versions]
      return false unless expected.is_a?(Hash)

      expected = expected.transform_keys(&:to_s)
      return false unless thread_ids.all? { |id| ReviewThreads::ContentDigest.valid?(expected[id]) }

      current = threads.index_by { |thread| thread[:id].to_s }
      thread_ids.all? { |id| current[id] && ReviewThreads::ContentDigest.call(current[id]) == expected[id] }
    end

    def stale_threads_result(agent_run_id, thread_ids)
      logger.warn(message: "agent_execution.review_thread_resolution_stale_threads", agent_run_id: agent_run_id,
        requested_thread_ids: thread_ids)
      { agent_run_id: agent_run_id, requested_thread_ids: thread_ids, resolved_count: 0, failed_count: 0, stale_threads: true }
    end
  end
end
