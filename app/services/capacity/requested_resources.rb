# frozen_string_literal: true

module Capacity
  class RequestedResources
    DISK_BYTES_DEFAULT = ExecutionRunners::WorkspaceStrategy.default_writable_dirs.sum(&:size_bytes)

    class << self
      def for_context(user:, project:, external_metadata: nil)
        normalize(external_metadata&.dig("requested_resources"), user: user, project: project) ||
          defaults_for(user: user, project: project)
      end

      def for_agent_run(agent_run)
        owner = agent_run.project&.effective_owner
        normalize(
          agent_run.external_metadata&.dig("requested_resources"),
          user: owner, project: agent_run.project, agent_run: agent_run
        ) || defaults_for(user: owner, project: agent_run.project)
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
          disk_bytes: DISK_BYTES_DEFAULT,
          profile: nil
        }
      end

      def normalize(raw, user: nil, project: nil, agent_run: nil)
        return if raw.blank?

        profile_name = raw["profile"].to_s.presence
        preset = if profile_name.present?
          ExecutionRunners::ExecutionResources.profile(profile_name)
        end

        {
          cpu_quota: raw["cpu_quota"].to_i.nonzero? || preset&.cpu_quota.to_i,
          memory_bytes: raw["memory_bytes"].to_i.nonzero? || preset&.memory_bytes.to_i,
          disk_bytes: raw["disk_bytes"].to_i.nonzero? || preset&.disk_bytes.to_i,
          profile: profile_name
        }
      rescue ArgumentError => e
        Rails.logger.warn(
          message: "capacity.requested_resources.unknown_profile",
          profile_name: profile_name,
          error: e.message,
          agent_run_id: agent_run&.id
        )
        requested_with_default_fallback(raw, user: user, project: project)
      end

      # An unknown profile must not zero out the request: admission and
      # accounting would treat the run as free while execution still consumes
      # the provisioner defaults. Explicit numeric overrides survive; fields
      # the requester left unset fall back to the usual default request
      # (CONTAINER-RUNTIME-027).
      def requested_with_default_fallback(raw, user:, project:)
        defaults = defaults_for(user: user, project: project)
        {
          cpu_quota: raw["cpu_quota"].to_i.nonzero? || defaults[:cpu_quota],
          memory_bytes: raw["memory_bytes"].to_i.nonzero? || defaults[:memory_bytes],
          disk_bytes: raw["disk_bytes"].to_i.nonzero? || defaults[:disk_bytes],
          profile: nil
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
