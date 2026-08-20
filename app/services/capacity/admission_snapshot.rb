# frozen_string_literal: true

module Capacity
  class AdmissionSnapshot
    class << self
      def capture(window_seconds:, now: Time.current)
        new(window_seconds:, now:).tap(&:capture!)
      end
    end

    def initialize(window_seconds:, now: Time.current, inflight_runs: nil, recent_starts: nil)
      @window_seconds = window_seconds.to_i
      @now = now
      @inflight_runs = inflight_runs
      @recent_starts = recent_starts
      @host_requested_resources = {}
      @host_scopes = {}
    end

    def capture!
      @inflight_runs ||= TenantContext.with_system_access do
        AgentRun.capacity_inflight.includes(project: { created_by: :user_setting }).to_a
      end
      @recent_starts ||= Capacity::ProvisioningRateWindow.recent_starts(
        window_seconds: window_seconds,
        now: now
      )
      @global_requested_resources = Capacity::RequestedResources.sum_runs(@inflight_runs)
      self
    end

    def global_requested_resources
      @global_requested_resources ||= Capacity::RequestedResources.sum_runs(inflight_runs)
    end

    def host_requested_resources(host)
      @host_requested_resources[host.to_s] ||= Capacity::RequestedResources.sum_runs(
        inflight_runs.select { |run| host_scope_for(host).include?(effective_host_for(run)) }
      )
    end

    def provisioning_window(account:, project:)
      account_starts = @recent_starts.select { |entry| entry[:account_id] == account&.id }
      project_starts = @recent_starts.select { |entry| entry[:project_id] == project&.id }

      {
        global_count: @recent_starts.size,
        account_count: account_starts.size,
        project_count: project_starts.size,
        next_available_at: next_available_at_for(@recent_starts),
        account_next_available_at: next_available_at_for(account_starts),
        project_next_available_at: next_available_at_for(project_starts)
      }
    end

    def record_started_run(agent_run, host:, started_at:)
      requested = Capacity::RequestedResources.for_agent_run(agent_run)
      inflight_runs << agent_run
      @global_requested_resources = global_requested_resources.dup
      add!(@global_requested_resources, requested)

      @host_requested_resources.each_key do |candidate_host|
        next unless host_scope_for(candidate_host).include?(host.to_s)

        @host_requested_resources[candidate_host] = @host_requested_resources[candidate_host].dup
        add!(@host_requested_resources[candidate_host], requested)
      end

      @recent_starts << {
        account_id: agent_run.project&.account_id,
        project_id: agent_run.project_id,
        started_at: started_at.in_time_zone
      }
    end

    private

    attr_reader :inflight_runs, :now, :window_seconds

    def add!(totals, requested)
      totals[:cpu_quota] += requested[:cpu_quota].to_i
      totals[:memory_bytes] += requested[:memory_bytes].to_i
      totals[:disk_bytes] += requested[:disk_bytes].to_i
    end

    def effective_host_for(run)
      run.container_host.to_s.presence || run.external_metadata&.dig("planned_container_host").to_s
    end

    def host_scope_for(host)
      @host_scopes[host.to_s] ||= begin
        backend = Containers.backend_for(host)
        identifiers = backend.all_host_identifiers.map(&:to_s)
        backend.remote? ? identifiers : identifiers + [ "" ]
      rescue Containers::Backends::Resolver::UnknownBackendError
        [ host.to_s ]
      end
    end

    def next_available_at_for(starts)
      starts.min_by { |entry| entry[:started_at] }&.fetch(:started_at)&.+(window_seconds)
    end
  end
end
