# frozen_string_literal: true

require "docker-api"
require "pathname"
require "timeout"

module Accounts
  module Operations
    class AutoCapacityObserver
      CACHE_VERSION = "v1"
      CACHE_TTL = 30.seconds
      SNAPSHOT_TIMEOUT = 4
      PAID_COMPOSE_PROJECT = "paid"
      DEFAULT_ESTIMATED_RUN_MEMORY_BYTES = Containers::Provision::DEFAULTS[:memory_bytes]
      ESTIMATED_RUN_MEMORY_MULTIPLIER = 1.25
      MIN_CONTROL_PLANE_MARGIN_BYTES = 512.megabytes
      CONTROL_PLANE_MARGIN_MULTIPLIER = 0.2
      CONTROL_PLANE_SERVICES = %w[
        postgres
        qdrant
        redis
        temporal
        temporal-admin-tools
        temporal-ui
        web
        worker
      ].freeze
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

        snapshot = Timeout.timeout(SNAPSHOT_TIMEOUT) { collect_snapshot }
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

      def degraded_snapshot_payload(snapshot)
        {
          status: :degraded,
          sampled_at: Time.current,
          docker_cpu_count: snapshot[:docker_cpu_count],
          docker_memory_bytes: snapshot[:docker_memory_bytes],
          running_agent_count: snapshot[:running_agent_count],
          estimated_next_run_memory_bytes: snapshot[:estimated_next_run_memory_bytes],
          available_agent_memory_bytes: snapshot[:available_agent_memory_bytes],
          control_plane_margin_bytes: snapshot[:control_plane_margin_bytes],
          effective_recommended_concurrency: nil,
          usage: snapshot[:usage],
          warnings: snapshot[:warnings],
          manual_mode_summary: manual_mode_summary,
          auto_mode_summary: degraded_auto_mode_summary,
          comparison_summary: degraded_comparison_summary
        }
      end

      def collect_snapshot
        daemon_info = docker_info
        usage = empty_usage
        running_agent_count = 0
        warnings = []

        backend.list_containers(all: false).each do |container|
          info = container.info
          stats = Containers::DockerStatsParser.parse_stats(backend.container_stats(container, stream: false))
          bucket = classify_container(info)

          usage[bucket][:container_count] += 1
          usage[bucket][:cpu_percent] += stats[:cpu_percent]
          usage[bucket][:memory_bytes] += stats[:memory_bytes]
          running_agent_count += 1 if counts_as_running_agent?(info)
        rescue StandardError => error
          warnings << "Some Docker metrics were unavailable while building the auto-capacity preview: #{error.message}"
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
        return backend.connection.info if backend.respond_to?(:connection)

        Docker.info
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

      def classify_container(info)
        labels = container_labels(info)
        compose_service = labels["com.docker.compose.service"]
        compose_project = labels["com.docker.compose.project"]
        compose_workdir = labels["com.docker.compose.project.working_dir"]

        return :service if labels["paid.service_container"] == "true"
        return :agent if labels["paid.agent_run_id"].present? || labels["paid.mcp_sidecar"] == "true" || labels["paid.container_pool"] == "true"
        return :paid if labels["paid.managed"] == "true" || labels["paid.resource"].present?
        return :paid if paid_control_plane_service?(compose_service:, compose_project:, compose_workdir:)

        :other
      end

      def paid_control_plane_service?(compose_service:, compose_project:, compose_workdir:)
        return false unless compose_service.present?
        return false unless CONTROL_PLANE_SERVICES.include?(compose_service)

        paid_compose_project?(compose_project) || paid_compose_workdir?(compose_workdir)
      end

      def paid_compose_project?(compose_project)
        normalize_compose_project(compose_project) == PAID_COMPOSE_PROJECT
      end

      def paid_compose_workdir?(compose_workdir)
        normalize_compose_workdir(compose_workdir)&.basename&.to_s == PAID_COMPOSE_PROJECT
      rescue ArgumentError
        false
      end

      def normalize_compose_project(compose_project)
        compose_project.to_s.strip.downcase
      end

      def normalize_compose_workdir(compose_workdir)
        raw = compose_workdir.to_s.strip
        return if raw.blank?

        Pathname.new(raw.tr("\\", "/")).cleanpath
      end

      def counts_as_running_agent?(info)
        labels = container_labels(info)

        labels["paid.agent_run_id"].present? && labels["paid.mcp_sidecar"] != "true"
      end

      def container_labels(info)
        info.fetch("Labels", {}).presence || info.dig("Config", "Labels") || {}
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
          .map(&:to_i)

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
