# frozen_string_literal: true

module Capacity
  class RequestedResources
    DISK_BYTES_DEFAULT = ExecutionRunners::WorkspaceStrategy.default_writable_dirs.sum(&:size_bytes)

    class << self
      def for_context(user:, project:, external_metadata: nil)
        normalize(external_metadata&.dig("requested_resources")) || defaults_for(user: user, project: project)
      end

      def for_agent_run(agent_run)
        owner = agent_run.project&.effective_owner
        for_context(user: owner, project: agent_run.project, external_metadata: agent_run.external_metadata)
      end

      def persistable_for(agent_run)
        for_agent_run(agent_run).transform_keys(&:to_s)
      end

      def sum_for(scope)
        sum_runs(scope.includes(project: { created_by: :user_setting }).to_a)
      end

      def sum_runs(runs)
        runs.each_with_object(zero) do |run, totals|
          add!(totals, for_agent_run(run))
        end
      end

      def zero
        {
          cpu_quota: 0,
          memory_bytes: 0,
          disk_bytes: 0
        }
      end

      private

      def defaults_for(user:, project:)
        {
          cpu_quota: Containers::Provision::DEFAULTS[:cpu_quota].to_i,
          memory_bytes: user&.settings&.container_memory_bytes.presence || Containers::Provision::DEFAULTS[:memory_bytes].to_i,
          disk_bytes: DISK_BYTES_DEFAULT
        }
      end

      def normalize(raw)
        return if raw.blank?

        {
          cpu_quota: raw["cpu_quota"].to_i,
          memory_bytes: raw["memory_bytes"].to_i,
          disk_bytes: raw["disk_bytes"].to_i
        }
      end

      def add!(totals, requested)
        totals[:cpu_quota] += requested[:cpu_quota].to_i
        totals[:memory_bytes] += requested[:memory_bytes].to_i
        totals[:disk_bytes] += requested[:disk_bytes].to_i
      end
    end
  end
end
