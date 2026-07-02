# frozen_string_literal: true

<<<<<<< HEAD
=======
require "pathname"
require "set"
>>>>>>> origin/main
require "timeout"

module Capacity
  class DockerSnapshot
<<<<<<< HEAD
    CACHE_KEY = "capacity/docker_snapshot/v1"
    CACHE_TTL = 15.seconds
    FETCH_TIMEOUT = 2.seconds
    PER_CONTAINER_TIMEOUT = 0.2.seconds
    MIN_SPIKE_MARGIN_BYTES = 256 * 1024 * 1024
    PAID_COMPOSE_PROJECT = "paid"
    PAID_CONTROL_PLANE_SERVICES = %w[
      postgres
      redis
      web
=======
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
    DOCKER_SAMPLING_BUDGET = 3.seconds
    PAID_COMPOSE_PROJECT = "paid"

    PAID_COMPOSE_SERVICES = %w[
      postgres
      redis
      web
      worker
>>>>>>> origin/main
      temporal
      temporal-ui
      temporal-admin-tools
      qdrant
<<<<<<< HEAD
      worker
    ].freeze

    class << self
      def fetch(...)
        new(...).fetch
      end
    end

    def fetch
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { build_snapshot }
=======
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
>>>>>>> origin/main
    end

    private

<<<<<<< HEAD
    def build_snapshot
      return unavailable_snapshot(reason: "unsupported_backend", confidence: "low") unless backend.identifier == "local"

      Timeout.timeout(FETCH_TIMEOUT) do
        running_containers = backend.list_containers(all: true).select { |container| running?(container) }
        metrics = collect_metrics(running_containers)
        categorized = categorize(running_containers, metrics)
        docker_memory_bytes = Docker.info["MemTotal"].to_i
        control_plane_memory_bytes = categorized[:paid_control_plane_memory_bytes]
        service_container_memory_bytes = categorized[:service_container_memory_bytes]
        unrelated_container_memory_bytes = categorized[:unrelated_container_memory_bytes]
        agent_memory_bytes = categorized[:agent_memory_bytes]
        reserved_non_agent_bytes =
          control_plane_memory_bytes + service_container_memory_bytes + unrelated_container_memory_bytes
        spike_margin_bytes = [ ((control_plane_memory_bytes + service_container_memory_bytes) * 0.15).to_i, MIN_SPIKE_MARGIN_BYTES ].max

        {
          available: docker_memory_bytes.positive?,
          reason: docker_memory_bytes.positive? ? nil : "docker_memory_unavailable",
          confidence: metrics.size == running_containers.size ? "high" : "low",
          snapshot_at: Time.current,
          docker_memory_bytes: docker_memory_bytes,
          agent_memory_bytes: agent_memory_bytes,
          paid_control_plane_memory_bytes: control_plane_memory_bytes,
          service_container_memory_bytes: service_container_memory_bytes,
          unrelated_container_memory_bytes: unrelated_container_memory_bytes,
          reserved_non_agent_bytes: reserved_non_agent_bytes,
          spike_margin_bytes: spike_margin_bytes,
          effective_agent_budget_bytes: [ docker_memory_bytes - reserved_non_agent_bytes - agent_memory_bytes - spike_margin_bytes, 0 ].max,
          running_container_count: running_containers.size,
          sampled_container_count: metrics.size
        }
      end
    rescue Timeout::Error
      unavailable_snapshot(reason: "docker_timeout", confidence: "low")
    rescue Docker::Error::DockerError, Excon::Error => e
      unavailable_snapshot(reason: "docker_error", confidence: "low", error_class: e.class.name, error_message: e.message)
    end

    def backend
      @backend ||= Containers.backend
    end

    def running?(container)
      state = container.info["State"]
      return state["Running"] == true if state.is_a?(Hash)

      state == "running"
    end

    def collect_metrics(containers)
      containers.each_with_object({}) do |container, metrics|
        metric = collect_container_metric(container)
        metrics[container.id] = metric if metric
      end
    end

    def collect_container_metric(container)
      Timeout.timeout(PER_CONTAINER_TIMEOUT) do
        raw = backend.container_stats(container, stream: false)
        Containers::DockerStatsParser.parse_stats(raw)
      end
    rescue Timeout::Error, Docker::Error::DockerError, Excon::Error
      nil
    end

    def categorize(containers, metrics)
      containers.each_with_object(
        agent_memory_bytes: 0,
        paid_control_plane_memory_bytes: 0,
        service_container_memory_bytes: 0,
        unrelated_container_memory_bytes: 0
      ) do |container, totals|
        metric = metrics[container.id]
        next unless metric

        labels = container.info.dig("Config", "Labels") || container.info["Labels"] || {}
        memory_bytes = metric[:memory_bytes].to_i

        if agent_related_container?(labels)
          totals[:agent_memory_bytes] += memory_bytes
        elsif labels["paid.service_container_id"].present?
          totals[:service_container_memory_bytes] += memory_bytes
        elsif paid_control_plane_container?(labels)
          totals[:paid_control_plane_memory_bytes] += memory_bytes
        else
          totals[:unrelated_container_memory_bytes] += memory_bytes
        end
      end
    end

    def agent_related_container?(labels)
      labels["paid.agent_run_id"].present? ||
        labels["paid.container_pool"] == "true" ||
        labels["paid.container_pool_entry_id"].present? ||
        labels["paid.mcp_sidecar"] == "true" ||
        labels["paid.managed"] == "true" ||
        labels["paid.resource"].present?
    end

    def paid_control_plane_container?(labels)
      labels["com.docker.compose.project"] == PAID_COMPOSE_PROJECT &&
        labels["com.docker.compose.service"].in?(PAID_CONTROL_PLANE_SERVICES)
    end

    def unavailable_snapshot(reason:, confidence:, **extra)
      {
        available: false,
        reason: reason,
        confidence: confidence,
        snapshot_at: Time.current,
        docker_memory_bytes: 0,
        agent_memory_bytes: 0,
        paid_control_plane_memory_bytes: 0,
        service_container_memory_bytes: 0,
        unrelated_container_memory_bytes: 0,
        reserved_non_agent_bytes: 0,
        spike_margin_bytes: 0,
        effective_agent_budget_bytes: 0,
        running_container_count: 0,
        sampled_container_count: 0
      }.merge(extra)
=======
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
      sampling_deadline = monotonic_now + DOCKER_SAMPLING_BUDGET
      running_containers = list_running_containers

      running_containers.each_with_index do |container, index|
        if sampling_budget_exceeded?(sampling_deadline)
          degraded_reasons << "container_sampling_budget_exceeded"
          classify_remaining_containers_as_other_docker(
            containers: running_containers.drop(index),
            bucket: buckets.fetch(:other_docker)
          )
          break
        end

        classification = classify_container(container: container, references: references)
        stats = sample_container(container, deadline: sampling_deadline)

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
      containers = with_timeout(DOCKER_LIST_TIMEOUT) do
        backend.list_containers(**backend.capacity_snapshot_list_container_options)
      end
      containers.select { |container| running_container?(container.info) }
    end

    def sample_container(container, deadline:)
      remaining_budget = deadline - monotonic_now
      return nil if remaining_budget <= 0

      raw = with_timeout([ DOCKER_CONTAINER_TIMEOUT, remaining_budget ].min) do
        backend.container_stats(container, stream: false)
      end
      parsed = Containers::DockerStatsParser.parse_stats(raw)

      {
        memory_bytes: parsed.fetch(:memory_bytes, 0).to_i,
        cpu_percent: parsed.fetch(:cpu_percent, 0.0).to_f.round(2)
      }
    rescue Timeout::Error, Docker::Error::DockerError, Docker::Error::ExconError, Excon::Error
      nil
    end

    def build_references
      TenantContext.with_system_access do
        host_scope = [ nil, "" ] + backend.all_host_identifiers
        active_runs = AgentRun.capacity_inflight.where(container_host: host_scope)

        {
          agent_container_ids: active_runs.where.not(container_id: nil).pluck(:container_id).to_set,
          mcp_sidecar_ids: active_runs.pluck(:mcp_sidecar_container_ids).flatten.compact.to_set,
          service_container_ids: ServiceContainer.running.where.not(docker_container_id: nil).pluck(:docker_container_id).to_set,
          chat_container_ids: ChatSession.active.where.not(container_id: nil).pluck(:container_id).to_set
        }
      end
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

    def classify_remaining_containers_as_other_docker(containers:, bucket:)
      containers.each do |_container|
        accumulate_bucket(bucket, memory_bytes: 0, cpu_percent: 0.0)
      end
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

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sampling_budget_exceeded?(deadline)
      monotonic_now >= deadline
    end

    def deep_dup_buckets
      EMPTY_BUCKETS.transform_values do |bucket|
        Bucket.new(
          container_count: bucket.container_count,
          memory_bytes: bucket.memory_bytes,
          cpu_percent: bucket.cpu_percent
        )
      end
>>>>>>> origin/main
    end
  end
end
