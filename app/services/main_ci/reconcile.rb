# frozen_string_literal: true

module MainCi
  # Provider events are hints. Only a fresh exact-head snapshot changes state.
  # @spec MAIN-CI-001 MAIN-CI-002 MAIN-CI-006 MAIN-CI-007
  class Reconcile
    def self.call(project:, client: nil)
      return unless Policy.new(project).enabled?

      new(project, client || project.client).call
    end

    def initialize(project, client)
      @project = project
      @client = client
    end

    def call
      state = nil
      @project.with_lock do
        snapshot = Snapshot.new(project: @project, client: @client)
        failures = snapshot.failures
        if failures.empty? && !snapshot.green?
          failures = snapshot.recent_failures
          failures = failures.select do |run|
            %w[ahead identical].include?(@client.compare(@project.full_name, run.fetch(:head_sha), snapshot.head.fetch(:sha)).status)
          end
          baseline = MainCiState.find_by(project: @project)&.verified_sha
          failures = failures.select { |run| @client.compare(@project.full_name, baseline, run.fetch(:head_sha)).status == "ahead" } if baseline
        end
        context = failure_context(failures) if failures.any?
        return unless @client.default_branch_head(@project.full_name) == snapshot.head

        state = MainCiState.find_or_initialize_by(project: @project, account: @project.account)
        previous_status = state.status
        state.observed_sha = snapshot.head.fetch(:sha)
        if snapshot.green?
          state.assign_attributes(status: "healthy", verified_sha: state.observed_sha, verified_at: Time.current,
            episode_key: nil, failed_sha: nil, failed_at: nil, dispatched_at: nil, repair_run: nil, dispatch_count: 0)
          state.evidence = state.evidence.merge("verified_runs" => snapshot.required_runs, "verified_branch" => snapshot.head[:branch])
        elsif failures.any?
          state.episode_key ||= SecureRandom.uuid
          state.failed_sha ||= failures.first.fetch(:head_sha)
          state.failed_at ||= Time.current
          state.status = "failing" unless state.repair_run_id
          state.evidence = state.evidence.merge("failed_runs" => failures, "failure_context_available" => context.checks.any?,
            "failure_history" => (state.evidence.fetch("failure_history", []) + failures).uniq { |run| run["id"] || run[:id] }.last(100),
            "failure_context" => [ context.output, state.evidence["failure_context"] ].compact.uniq.join("\n").first(8_000),
            "failing_examples" => (state.evidence.fetch("failing_examples", []) + context.output.scan(%r{spec/[\w/.-]+_spec\.rb(?::\d+|\[[\d:,]+\])})).uniq.first(100))
        elsif state.status == "healthy"
          state.status = "unverified"
        end
        state.save!
        if previous_status != state.status
          Audit::RecordEvent.call(action: "main_ci.transition", subject: @project,
            metadata: { from: previous_status, to: state.status, sha: state.observed_sha, episode: state.episode_key })
        end
      end
      Dispatch.call(state: state, client: @client) if state.episode_key
      state
    end

    private

    def failure_context(failures)
      checks = @client.check_runs_for_ref(@project.full_name, failures.first.fetch(:head_sha))
      Ci::FailureContext.call(repo: @project.full_name, checks: checks, github_client: @client,
        ref: failures.first.fetch(:head_sha), max_chars: 8_000)
    rescue GithubClient::Error
      Ci::FailureContext.call(repo: @project.full_name, checks: [], github_client: @client)
    end
  end
end
