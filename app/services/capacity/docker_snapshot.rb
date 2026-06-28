# frozen_string_literal: true

require "set"
require "timeout"

module Capacity
  class DockerSnapshot
    Bucket = Struct.new(:container_count, :memory_bytes, :cpu_percent, keyword_init: true) do
      def to_h
        {
          container_count: container_count,
          memory_bytes: memory_bytes,
          cpu_percent: cpu_percent
        }
      end
    end

    Snapshot = Struct.new(
      :backend_identifier,
      :docker_cpu_count,
      :docker_memory_bytes,
      :usage_buckets,
      :available_memory_bytes,
      :agent_container_count,
      :snapshot_at,
      :confidence,
      :degraded,
      :degraded_reasons,
      keyword_init: true
    ) do
      def degraded?
        degraded
      end

      def fresh?(now: Time.current)
        snapshot_at.present? && snapshot_at >= now - DockerSnapshot::CACHE_TTL
      end

      def freshness_seconds(now: Time.current)
        return nil unless snapshot_at

        [ (now - snapshot_at).to_i, 0 ].max
      end

      def stale?(now: Time.current)
        !fresh?(now: now)
      end

      def bucket(name)
        usage_buckets.fetch(name.to_sym)
      end

      def paid_control_plane_memory_bytes
        bucket(:paid_control_plane).memory_bytes
      end

      def paid_agent_memory_bytes
        bucket(:paid_agents).memory_bytes
      end

      def paid_service_container_memory_bytes
        bucket(:paid_service_containers).memory_bytes
      end

      def other_docker_memory_bytes
        bucket(:other_docker).memory_bytes
      end

      def to_h
        {
          backend_identifier: backend_identifier,
          docker_cpu_count: docker_cpu_count,
          docker_memory_bytes: docker_memory_bytes,
          usage_buckets: usage_buckets.transform_values(&:to_h),
          available_memory_bytes: available_memory_bytes,
          agent_container_count: agent_container_count,
          snapshot_at: snapshot_at,
          confidence: confidence,
          degraded: degraded,
          degraded_reasons: degraded_reasons
        }
      end
    end

    CACHE_TTL = 15.seconds
    STALE_CACHE_TTL = 2.minutes
    DOCKER_INFO_TIMEOUT = 2.seconds
    DOCKER_LIST_TIMEOUT = 2.seconds
    DOCKER_CONTAINER_TIMEOUT = 1.second

    PAID_COMPOSE_SERVICES = %w[
      postgres
      redis
      web
      worker
      temporal
      temporal-ui
      temporal-admin-tools
      qdrant
      agent-image
      agent-test
    ].freeze
    CACHE_VERSION = "v1"
    EMPTY_BUCKETS = %i[
      paid_control_plane
      paid_agents
      paid_service_containers
      other_docker
    ].index_with { Bucket.new(container_count: 0, memory_bytes: 0, cpu_percent: 0.0) }.freeze

    def self.call(...)
      new(...).call
    end

    def self.cache_key(backend_identifier)
      "capacity/docker_snapshot/#{backend_identifier}/#{CACHE_VERSION}"
    end

    def self.serialize(snapshot)
      return if snapshot.nil?

      snapshot.to_h
    end

    def self.deserialize(data)
      return if data.blank?

      Snapshot.new(
        backend_identifier: fetch_value(data, :backend_identifier),
        docker_cpu_count: fetch_value(data, :docker_cpu_count),
        docker_memory_bytes: fetch_value(data, :docker_memory_bytes),
        usage_buckets: deserialize_buckets(fetch_value(data, :usage_buckets)),
        available_memory_bytes: fetch_value(data, :available_memory_bytes),
        agent_container_count: fetch_value(data, :agent_container_count),
        snapshot_at: fetch_value(data, :snapshot_at),
        confidence: fetch_value(data, :confidence),
        degraded: fetch_value(data, :degraded),
        degraded_reasons: Array(fetch_value(data, :degraded_reasons)).map(&:to_s)
      )
    end

    def self.deserialize_buckets(data)
      EMPTY_BUCKETS.keys.index_with do |name|
        values = fetch_value(data, name, default: {})
        Bucket.new(
          container_count: fetch_value(values, :container_count, default: 0).to_i,
          memory_bytes: fetch_value(values, :memory_bytes, default: 0).to_i,
          cpu_percent: fetch_value(values, :cpu_percent, default: 0.0).to_f.round(2)
        )
      end
    end

    def self.fetch_value(data, key, default: nil)
      return default unless data.respond_to?(:key?)

      return data[key] if data.key?(key)

      string_key = key.to_s
      return data[string_key] if data.key?(string_key)

      default
    end

    def initialize(backend: Containers.backend, now: Time.current, cache: Rails.cache, force_refresh: false)
      @backend = backend
      @now = now
      @cache = cache
      @force_refresh = force_refresh
    end

    def call
      cached_snapshot = read_cached_snapshot
      return cached_snapshot if cached_snapshot.present? && !force_refresh && cached_snapshot.fresh?(now: now)

      snapshot = collect_snapshot
      write_snapshot(snapshot)
      snapshot
    rescue Timeout::Error, Docker::Error::DockerError, Docker::Error::ExconError, Excon::Error => e
      fallback_snapshot(cached_snapshot, reason: failure_reason_for(e))
    rescue => e
      fallback_snapshot(cached_snapshot, reason: failure_reason_for(e))
    end

    private

    attr_reader :backend, :now, :cache, :force_refresh

    def read_cached_snapshot
      self.class.deserialize(cache.read(cache_key))
    end

    def write_snapshot(snapshot)
      cache.write(cache_key, self.class.serialize(snapshot), expires_in: STALE_CACHE_TTL)
    end

    def cache_key
      self.class.cache_key(backend.identifier)
    end

    def collect_snapshot
      system_info = docker_info
      references = build_references
      buckets = deep_dup_buckets
      degraded_reasons = []

      list_running_containers.each do |container|
        classification = classify_container(container: container, references: references)
        stats = sample_container(container)

        if stats.nil?
          degraded_reasons << "container_sample_failed"
          classification = :other_docker
        end

        accumulate_bucket(
          buckets.fetch(classification),
          memory_bytes: stats&.fetch(:memory_bytes, 0) || 0,
          cpu_percent: stats&.fetch(:cpu_percent, 0.0) || 0.0
        )
      end

      available_memory_bytes = degraded_reasons.empty? ? remaining_memory(system_info: system_info, buckets: buckets) : 0

      Snapshot.new(
        backend_identifier: backend.identifier,
        docker_cpu_count: system_info.fetch("NCPU", 0).to_i,
        docker_memory_bytes: system_info.fetch("MemTotal", 0).to_i,
        usage_buckets: buckets,
        available_memory_bytes: available_memory_bytes,
        agent_container_count: buckets.fetch(:paid_agents).container_count,
        snapshot_at: now,
        confidence: confidence_for(degraded_reasons),
        degraded: degraded_reasons.any?,
        degraded_reasons: degraded_reasons.uniq
      )
    end

    def docker_info
      with_timeout(DOCKER_INFO_TIMEOUT) { backend.system_info }
    end

    def list_running_containers
      containers = with_timeout(DOCKER_LIST_TIMEOUT) { backend.list_containers }
      containers.select { |container| running_container?(container.info) }
    end

    def sample_container(container)
      raw = with_timeout(DOCKER_CONTAINER_TIMEOUT) { backend.container_stats(container, stream: false) }
      parsed = Containers::DockerStatsParser.parse_stats(raw)

      {
        memory_bytes: parsed.fetch(:memory_bytes, 0).to_i,
        cpu_percent: parsed.fetch(:cpu_percent, 0.0).to_f.round(2)
      }
    rescue Timeout::Error, Docker::Error::DockerError, Docker::Error::ExconError, Excon::Error
      nil
    end

    def build_references
      host_scope = [ nil, "" ] + backend.all_host_identifiers
      active_runs = AgentRun.capacity_inflight.where(container_host: host_scope)

      {
        agent_container_ids: active_runs.where.not(container_id: nil).pluck(:container_id).to_set,
        mcp_sidecar_ids: active_runs.pluck(:mcp_sidecar_container_ids).flatten.compact.to_set,
        service_container_ids: ServiceContainer.running.where.not(docker_container_id: nil).pluck(:docker_container_id).to_set,
        chat_container_ids: ChatSession.active.where.not(container_id: nil).pluck(:container_id).to_set
      }
    end

    def classify_container(container:, references:)
      info = container.info
      labels = container_labels(info)
      container_id = container.id

      return :paid_service_containers if service_container?(labels: labels, container_id: container_id, references: references)
      return :paid_agents if paid_agent?(labels: labels, container_id: container_id, references: references)
      return :paid_control_plane if control_plane_container?(labels: labels, container_id: container_id, references: references)

      :other_docker
    end

    def service_container?(labels:, container_id:, references:)
      labels["paid.service_container"] == "true" ||
        references.fetch(:service_container_ids).include?(container_id)
    end

    def paid_agent?(labels:, container_id:, references:)
      labels["paid.agent_run_id"].present? ||
        labels["paid.mcp_sidecar"] == "true" ||
        labels["paid.container_pool"] == "true" ||
        references.fetch(:agent_container_ids).include?(container_id) ||
        references.fetch(:mcp_sidecar_ids).include?(container_id)
    end

    def control_plane_container?(labels:, container_id:, references:)
      return true if references.fetch(:chat_container_ids).include?(container_id)
      return true if labels["paid.managed"] == "true"
      return true if labels["paid.resource"].present?

      compose_service = labels["com.docker.compose.service"]
      compose_project = labels["com.docker.compose.project"]
      compose_workdir = labels["com.docker.compose.project.working_dir"]

      return false unless compose_service.present?
      return false unless PAID_COMPOSE_SERVICES.include?(compose_service)

      compose_project == "paid" || compose_workdir.to_s.include?("/paid")
    end

    def container_labels(info)
      info.fetch("Labels", {}).presence || info.dig("Config", "Labels") || {}
    end

    def running_container?(info)
      state = info["State"]
      return true if state == "running"
      return state["Running"] if state.is_a?(Hash) && state.key?("Running")
      return state["Status"] == "running" if state.is_a?(Hash)

      info["Status"] == "running"
    end

    def accumulate_bucket(bucket, memory_bytes:, cpu_percent:)
      bucket.container_count += 1
      bucket.memory_bytes += memory_bytes
      bucket.cpu_percent = (bucket.cpu_percent + cpu_percent).round(2)
    end

    def remaining_memory(system_info:, buckets:)
      used_memory = buckets.values.sum(&:memory_bytes)
      [ system_info.fetch("MemTotal", 0).to_i - used_memory, 0 ].max
    end

    def confidence_for(reasons)
      return 1.0 if reasons.empty?

      0.25
    end

    def fallback_snapshot(cached_snapshot, reason:)
      if cached_snapshot.present?
        Snapshot.new(
          backend_identifier: cached_snapshot.backend_identifier,
          docker_cpu_count: cached_snapshot.docker_cpu_count,
          docker_memory_bytes: cached_snapshot.docker_memory_bytes,
          usage_buckets: cached_snapshot.usage_buckets,
          available_memory_bytes: 0,
          agent_container_count: cached_snapshot.agent_container_count,
          snapshot_at: cached_snapshot.snapshot_at,
          confidence: 0.1,
          degraded: true,
          degraded_reasons: (cached_snapshot.degraded_reasons + [ "stale_cache", reason ]).uniq
        )
      else
        Snapshot.new(
          backend_identifier: backend.identifier,
          docker_cpu_count: 0,
          docker_memory_bytes: 0,
          usage_buckets: deep_dup_buckets,
          available_memory_bytes: 0,
          agent_container_count: 0,
          snapshot_at: now,
          confidence: 0.0,
          degraded: true,
          degraded_reasons: [ reason ]
        )
      end
    end

    def failure_reason_for(error)
      case error
      when Timeout::Error
        "docker_timeout"
      when Docker::Error::DockerError, Docker::Error::ExconError, Excon::Error
        "docker_unavailable"
      else
        "snapshot_failed"
      end
    end

    def with_timeout(duration, &block)
      Timeout.timeout(duration, &block)
    end

    def deep_dup_buckets
      EMPTY_BUCKETS.transform_values do |bucket|
        Bucket.new(
          container_count: bucket.container_count,
          memory_bytes: bucket.memory_bytes,
          cpu_percent: bucket.cpu_percent
        )
      end
    end
  end
end
