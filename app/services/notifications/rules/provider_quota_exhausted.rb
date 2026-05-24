# frozen_string_literal: true

module Notifications
  module Rules
    class ProviderQuotaExhausted < Rule
      SOURCE = "provider_quota_exhausted"
      WARNING_THRESHOLD = 15.minutes
      ERROR_THRESHOLD = 2.hours

      private

      def source = SOURCE

      def detect(scope)
        providers = Array(scope)
        precompute_blocked_run_counts(providers)

        providers.select do |provider|
          quota_state_for(provider)&.rate_limited? && quota_duration_for(provider) >= WARNING_THRESHOLD
        end
      end

      def build(provider)
        duration = quota_duration_for(provider)
        state = quota_state_for(provider)

        {
          severity: duration >= ERROR_THRESHOLD ? :error : :warning,
          title: "#{provider.display_name} quota exhausted for #{human_duration(state.updated_at)}",
          description: description_for(provider, state),
          nav_section: "runners",
          action_url: edit_runner_path(provider),
          metadata: {
            blocked_run_count: blocked_run_count_for(provider),
            reset_at: state.rate_limited_until&.iso8601
          }.compact
        }
      end

      def description_for(provider, state)
        parts = []
        parts << "#{blocked_run_count_for(provider)} unfinished runs blocked"
        parts << "resets at #{state.rate_limited_until.iso8601}" if state.rate_limited_until
        parts << "open runner settings at #{edit_runner_path(provider)}"
        parts.join(". ")
      end

      def quota_duration_for(provider)
        Time.current - quota_state_for(provider).updated_at
      end

      def quota_state_for(provider)
        @quota_states ||= {}
        @quota_states[provider.id] ||= provider.user.runner_states.find { |state| state.runner_name == provider.state_key }
      end

      def blocked_run_count_for(provider)
        @blocked_run_counts[provider.id] || 0
      end

      # Batch-load all blocked run counts for the given providers in a single
      # query, grouped by user, instead of issuing per-provider lookups.
      def precompute_blocked_run_counts(providers)
        @blocked_run_counts = {}
        return if providers.empty?

        user_ids = providers.map(&:user_id).uniq
        rows = AgentRun
          .joins(:project)
          .where(projects: { created_by_id: user_ids })
          .where(status: AgentRun::UNFINISHED_STATUSES)
          .pluck(:final_runner, :agent_type, "projects.created_by_id")

        providers.each do |provider|
          @blocked_run_counts[provider.id] = rows.count do |final, agent, uid|
            uid == provider.user_id && provider.matches_identifier?(final.presence || agent)
          end
        end
      end
    end
  end
end
