# frozen_string_literal: true

require "timeout"

module Accounts
  module Operations
    class AutoCapacityObserver
      CACHE_VERSION = "v1"
      CACHE_TTL = 30.seconds
      DOCKER_INFO_TIMEOUT = Capacity::DockerSnapshot::DOCKER_INFO_TIMEOUT
      DOCKER_LIST_TIMEOUT = Capacity::DockerSnapshot::DOCKER_LIST_TIMEOUT
      DOCKER_CONTAINER_TIMEOUT = Capacity::DockerSnapshot::DOCKER_CONTAINER_TIMEOUT
      DOCKER_SAMPLING_BUDGET = Capacity::DockerSnapshot::DOCKER_SAMPLING_BUDGET
      DEFAULT_ESTIMATED_RUN_MEMORY_BYTES = Containers::Provision::DEFAULTS[:memory_bytes]
      ESTIMATED_RUN_MEMORY_MULTIPLIER = 1.25
      MIN_CONTROL_PLANE_MARGIN_BYTES = 512.megabytes
      CONTROL_PLANE_MARGIN_MULTIPLIER = 0.2
      SAMPLING_WARNING_PREFIX = "Some Docker metrics were unavailable while building the auto-capacity preview"
      EMPTY_USAGE_BUCKET = {
        container_count: 0,
        cpu_percent: 0.0,
        memory_bytes: 0
      }.freeze

      def self.call(...)
        new(...).call
      end

      def initialize(account:, manual_limit:, backend: Containers.backend, cache: Rails.cache)
        @account = account
        @manual_limit = manual_limit
        @backend = backend
        @cache = cache
      end

      def call
        cache.fetch(cache_key, expires_in: CACHE_TTL) { build_payload_or_degraded }
      end

      private

      attr_reader :account, :manual_limit, :backend, :cache

      def build_payload_or_degraded
        build_payload
      rescue StandardError => error
        degraded_payload(
          warning: "Auto preview is degraded because Docker metrics could not be collected.",
          detail: error.message
        )
      end

      def cache_key
        [
          "accounts",
          "operations",
          "auto-capacity",
          CACHE_VERSION,
          account.id,
          backend.identifier,
          manual_limit || "none"
        ].join(":")
      end

      def build_payload
        return remote_backend_payload unless local_backend?

        snapshot = collect_snapshot
        if snapshot[:warnings].any?
          return degraded_snapshot_payload(snapshot)
        end

        recommended_concurrency = recommended_concurrency_for(snapshot)

        {
          status: :healthy,
          sampled_at: Time.current,
          docker_cpu_count: snapshot[:docker_cpu_count],
          docker_memory_bytes: snapshot[:docker_memory_bytes],
          running_agent_count: snapshot[:running_agent_count],
          estimated_next_run_memory_bytes: snapshot[:estimated_next_run_memory_bytes],
          available_agent_memory_bytes: snapshot[:available_agent_memory_bytes],
          control_plane_margin_bytes: snapshot[:control_plane_margin_bytes],
          effective_recommended_concurrency: recommended_concurrency,
          usage: snapshot[:usage],
          warnings: snapshot[:warnings],
          manual_mode_summary: manual_mode_summary,
          auto_mode_summary: auto_mode_summary(
            recommended_concurrency: recommended_concurrency,
            available_agent_memory_bytes: snapshot[:available_agent_memory_bytes],
            estimated_next_run_memory_bytes: snapshot[:estimated_next_run_memory_bytes]
          ),
          comparison_summary: comparison_summary(recommended_concurrency)
        }
      end

      # Sampling warnings mean some containers' memory was never accounted for
      # (budget exhausted or per-container stats failed). The partially
      # collected usage therefore undercounts real memory, which would make the
      # computed headroom and safety margin read optimistically large. Clear
      # both derived fields so the degraded preview never advertises capacity it
      # cannot actually defend.
      def degraded_snapshot_payload(snapshot)
        {
          status: :degraded,
          sampled_at: Time.current,
          docker_cpu_count: snapshot[:docker_cpu_count],
          docker_memory_bytes: snapshot[:docker_memory_bytes],
          running_agent_count: snapshot[:running_agent_count],
          estimated_next_run_memory_bytes: snapshot[:estimated_next_run_memory_bytes],
          available_agent_memory_bytes: nil,
          control_plane_margin_bytes: nil,
          effective_recommended_concurrency: nil,
          usage: snapshot[:usage],
          warnings: snapshot[:warnings],
          manual_mode_summary: manual_mode_summary,
          auto_mode_summary: degraded_auto_mode_summary,
          comparison_summary: degraded_comparison_summary
        }
      end

      def collect_snapshot
        inventory = docker_container_inventory
        daemon_info = docker_info
        usage = empty_usage
        running_agent_count = 0
        warnings = []
        deadline = monotonic_now + DOCKER_SAMPLING_BUDGET
        references = inventory.build_references
        containers = inventory.list_running_containers(timeout: DOCKER_LIST_TIMEOUT)

        results = Capacity::ConcurrentStatsSampler.call(
          containers: containers,
          monotonic_deadline: deadline,
          per_container_timeout: DOCKER_CONTAINER_TIMEOUT
        ) { |container| backend.container_stats(container, stream: false) }

        unsampled = results.count(&:skipped)
        if unsampled.positive?
          warnings << sampling_budget_warning(unsampled)
          usage[:other][:container_count] += unsampled
        end

        results.each do |result|
          next if result.skipped

          if result.error
            warnings << sampling_warning(result.error)
            next
          end

          stats = Containers::DockerStatsParser.parse_stats(result.raw_stats)
          bucket = usage_bucket_for(inventory.classify_container(container: result.container, references:))

          usage[bucket][:container_count] += 1
          usage[bucket][:cpu_percent] += stats[:cpu_percent]
          usage[bucket][:memory_bytes] += stats[:memory_bytes]
          running_agent_count += 1 if inventory.running_paid_agent_container?(container: result.container, references:)
        rescue StandardError => error
          warnings << sampling_warning(error)
        end

        paid_memory_bytes = usage[:paid][:memory_bytes]
        agent_memory_bytes = usage[:agent][:memory_bytes]
        non_agent_memory_bytes = paid_memory_bytes + usage[:service][:memory_bytes] + usage[:other][:memory_bytes]
        control_plane_margin_bytes = [ (paid_memory_bytes * CONTROL_PLANE_MARGIN_MULTIPLIER).ceil, MIN_CONTROL_PLANE_MARGIN_BYTES ].max
        available_agent_memory_bytes = [
          daemon_info.fetch("MemTotal", 0).to_i - non_agent_memory_bytes - agent_memory_bytes - control_plane_margin_bytes,
          0
        ].max

        {
          docker_cpu_count: daemon_info.fetch("NCPU", 0).to_i,
          docker_memory_bytes: daemon_info.fetch("MemTotal", 0).to_i,
          usage: finalize_usage(usage),
          running_agent_count: running_agent_count,
          estimated_next_run_memory_bytes: estimated_next_run_memory_bytes,
          available_agent_memory_bytes: available_agent_memory_bytes,
          control_plane_margin_bytes: control_plane_margin_bytes,
          warnings: warnings
        }
      end

      def docker_info
        with_timeout(DOCKER_INFO_TIMEOUT) { backend.system_info }
      end

      def docker_container_inventory
        @docker_container_inventory ||= Capacity::DockerContainerInventory.new(backend: backend)
      end

      def with_timeout(duration)
        Timeout.timeout(duration) { yield }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def sampling_warning(error)
        "#{SAMPLING_WARNING_PREFIX}: #{error.message}"
      end

      def sampling_budget_warning(unsampled)
        noun = (unsampled == 1) ? "container" : "containers"
        "#{SAMPLING_WARNING_PREFIX}: container sampling budget exceeded with #{unsampled} #{noun} unsampled"
      end

      def empty_usage
        {
          paid: EMPTY_USAGE_BUCKET.dup,
          agent: EMPTY_USAGE_BUCKET.dup,
          service: EMPTY_USAGE_BUCKET.dup,
          other: EMPTY_USAGE_BUCKET.dup
        }
      end

      def finalize_usage(usage)
        usage.transform_values do |bucket|
          bucket.merge(cpu_percent: bucket[:cpu_percent].round(2))
        end
      end

      def usage_bucket_for(classification)
        case classification
        when :paid_control_plane then :paid
        when :paid_agents then :agent
        when :paid_service_containers then :service
        else :other
        end
      end

      # Only the local Docker backend can give us a host-level preview: swarm
      # nodes each carry their own docker_info and the list payload differs
      # from a plain `docker ps`, and remote deployments are explicitly out of
      # scope for the auto-capacity preview.
      def local_backend?
        !backend.remote? && backend.identifier.to_s == "local"
      end

      def estimated_next_run_memory_bytes
        recent_peak_bytes = AgentRun.joins(:project)
          .where(projects: { account_id: account.id })
          .where.not(peak_memory_bytes: nil)
          .order(created_at: :desc)
          .limit(20)
          .pluck(:peak_memory_bytes)

        return DEFAULT_ESTIMATED_RUN_MEMORY_BYTES if recent_peak_bytes.empty?

        (recent_peak_bytes.max * ESTIMATED_RUN_MEMORY_MULTIPLIER).ceil
      end

      def recommended_concurrency_for(snapshot)
        estimate = snapshot[:estimated_next_run_memory_bytes]
        return 0 if estimate <= 0

        (snapshot[:available_agent_memory_bytes] / estimate).floor
      end

      def manual_mode_summary
        if manual_limit.present?
          "Manual mode is enforcing a fixed limit of #{manual_limit} concurrent runs today."
        else
          "Manual mode is using the current guardrail configuration without an explicit run concurrency ceiling."
        end
      end

      def auto_mode_summary(recommended_concurrency:, available_agent_memory_bytes:, estimated_next_run_memory_bytes:)
        "Auto preview would allow #{recommended_concurrency} concurrent runs because Docker currently has " \
          "#{human_size(available_agent_memory_bytes)} available for agents and recent runs suggest " \
          "#{human_size(estimated_next_run_memory_bytes)} per run."
      end

      def comparison_summary(recommended_concurrency)
        return "Manual mode is stricter than the auto preview right now." if manual_limit.present? && manual_limit < recommended_concurrency
        return "Auto preview is more conservative than the current manual limit." if manual_limit.present? && manual_limit > recommended_concurrency
        return "Manual and auto would currently allow the same concurrency." if manual_limit.present?

        "Auto preview is advisory only until automatic admission is enabled."
      end

      def degraded_auto_mode_summary
        "Auto preview cannot make a trustworthy recommendation until Docker metrics recover."
      end

      def degraded_comparison_summary
        "Keep using manual mode until the Docker inspection path is healthy again."
      end

      def human_size(bytes)
        ActionController::Base.helpers.number_to_human_size(bytes)
      end

      def remote_backend_payload
        degraded_payload(
          warning: "Auto preview is only available for local Docker backends.",
          detail: "This deployment is using the #{backend.identifier.inspect} Docker backend."
        )
      end

      def degraded_payload(warning:, detail:)
        {
          status: :degraded,
          sampled_at: Time.current,
          docker_cpu_count: nil,
          docker_memory_bytes: nil,
          running_agent_count: nil,
          estimated_next_run_memory_bytes: estimated_next_run_memory_bytes,
          available_agent_memory_bytes: nil,
          control_plane_margin_bytes: nil,
          effective_recommended_concurrency: nil,
          usage: empty_usage,
          warnings: [ "#{warning} #{detail}" ],
          manual_mode_summary: manual_mode_summary,
          auto_mode_summary: degraded_auto_mode_summary,
          comparison_summary: degraded_comparison_summary
        }
      end
    end
  end
end
