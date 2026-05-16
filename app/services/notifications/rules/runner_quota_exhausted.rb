# frozen_string_literal: true

module Notifications
  module Rules
    class RunnerQuotaExhausted < Rule
      SOURCE = "runner_quota_exhausted"
      WARNING_THRESHOLD = 15.minutes
      ERROR_THRESHOLD = 2.hours

      private

      def source = SOURCE

      def detect(scope)
        runners = Array(scope)
        precompute_blocked_run_counts(runners)

        runners.select do |runner|
          quota_state_for(runner)&.rate_limited? && quota_duration_for(runner) >= WARNING_THRESHOLD
        end
      end

      def build(runner)
        duration = quota_duration_for(runner)
        state = quota_state_for(runner)

        {
          severity: duration >= ERROR_THRESHOLD ? :error : :warning,
          title: "#{runner.display_name} quota exhausted for #{human_duration(state.updated_at)}",
          description: description_for(runner, state),
          nav_section: "providers",
          action_url: edit_runner_path(runner),
          metadata: {
            blocked_run_count: blocked_run_count_for(runner),
            reset_at: state.rate_limited_until&.iso8601
          }.compact
        }
      end

      def description_for(runner, state)
        parts = []
        parts << "#{blocked_run_count_for(runner)} unfinished runs blocked"
        parts << "resets at #{state.rate_limited_until.iso8601}" if state.rate_limited_until
        parts << "open runner settings at #{edit_runner_path(runner)}"
        parts.join(". ")
      end

      def quota_duration_for(runner)
        Time.current - quota_state_for(runner).updated_at
      end

      def quota_state_for(runner)
        @quota_states ||= {}
        @quota_states[runner.id] ||= runner.user.runner_states.find { |ps| ps.runner_name == runner.state_key }
      end

      def blocked_run_count_for(runner)
        @blocked_run_counts[runner.id] || 0
      end

      def precompute_blocked_run_counts(runners)
        @blocked_run_counts = {}
        return if runners.empty?

        user_ids = runners.map(&:user_id).uniq
        rows = AgentRun
          .joins(:project)
          .where(projects: { created_by_id: user_ids })
          .where(status: AgentRun::UNFINISHED_STATUSES)
          .pluck(:final_runner, :agent_type, "projects.created_by_id")

        runners.each do |runner|
          @blocked_run_counts[runner.id] = rows.count do |final, agent, uid|
            uid == runner.user_id && runner.matches_identifier?(final.presence || agent)
          end
        end
      end
    end
  end
end
