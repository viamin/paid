# frozen_string_literal: true

require "timeout"

module Capacity
  class DockerSnapshot
    MIN_SPIKE_MARGIN_BYTES = 256 * 1024 * 1024

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
      :backend_kind,
      :backend_shared,
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

      # Coarse classification of the connected Docker daemon. Used by
      # Capacity::Policy to gate whether auto mode is eligible for the
      # current deployment.
      def local?
        backend_kind.to_s == "local"
      end

      def remote?
        backend_kind.to_s == "remote"
      end

      def swarm?
        backend_kind.to_s == "swarm"
      end

      def shared?
        backend_shared == true
      end

      def to_h
        {
          backend_identifier: backend_identifier,
          backend_kind: backend_kind,
          backend_shared: backend_shared,
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

      def to_run_admission_h
        control_plane_memory_bytes = paid_control_plane_memory_bytes
        service_container_memory_bytes = paid_service_container_memory_bytes
        unrelated_container_memory_bytes = other_docker_memory_bytes
        agent_memory_bytes = paid_agent_memory_bytes
        reserved_non_agent_bytes = control_plane_memory_bytes + service_container_memory_bytes + unrelated_container_memory_bytes
        spike_margin_bytes = if available_memory_bytes.positive?
          [ ((control_plane_memory_bytes + service_container_memory_bytes) * 0.15).to_i, DockerSnapshot::MIN_SPIKE_MARGIN_BYTES ].min
        else
          0
        end
        effective_agent_budget_bytes = [ available_memory_bytes - spike_margin_bytes, 0 ].max
        available = !degraded? && docker_memory_bytes.positive?

        {
          available: available,
          reason: available ? nil : degraded_reasons.last || "docker_memory_unavailable",
          degraded_reasons: degraded_reasons,
          confidence: confidence,
          snapshot_at: snapshot_at,
          backend_identifier: backend_identifier,
          docker_memory_bytes: docker_memory_bytes,
          agent_container_count: agent_container_count,
          agent_memory_bytes: agent_memory_bytes,
          paid_control_plane_memory_bytes: control_plane_memory_bytes,
          service_container_memory_bytes: service_container_memory_bytes,
          unrelated_container_memory_bytes: unrelated_container_memory_bytes,
          reserved_non_agent_bytes: reserved_non_agent_bytes,
          spike_margin_bytes: spike_margin_bytes,
          effective_agent_budget_bytes: effective_agent_budget_bytes,
          running_container_count: usage_buckets.values.sum(&:container_count),
          sampled_container_count: usage_buckets.values.sum(&:container_count),
          error_class: nil,
          error_message: nil
        }
      end
    end

    CACHE_TTL = 15.seconds
    STALE_CACHE_TTL = 2.minutes
    DOCKER_INFO_TIMEOUT = 2.seconds
    DOCKER_LIST_TIMEOUT = 2.seconds
    # Docker's non-streaming stats endpoint samples two CPU counters across
    # an interval, so a single call routinely takes 1-2s alone and measurably
    # longer once several calls are in flight at once against the same
    # daemon. Sampling runs concurrently (see ConcurrentStatsSampler) bounded
    # by ConcurrentStatsSampler::MAX_THREADS, so this budget covers a couple
    # of worker batches rather than scaling with total container count.
    DOCKER_CONTAINER_TIMEOUT = 4.seconds
    DOCKER_SAMPLING_BUDGET = 10.seconds
    PAID_COMPOSE_PROJECT = "paid"

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

    def self.fetch(...)
      new(...).fetch
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
        backend_kind: fetch_value(data, :backend_kind),
        backend_shared: fetch_value(data, :backend_shared),
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
      # @spec CONTAINER-RUNTIME-005
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

    def fetch
      # @spec CONTAINER-RUNTIME-005
      call.to_run_admission_h
    end

    private

    attr_reader :backend, :cache, :force_refresh, :now

    # Categorizes the connected Docker backend so Capacity::Policy can
    # reason about whether auto mode is appropriate. Shared daemons
    # (multi-tenant remote endpoints, cluster managers) default to
    # manual mode because Paid cannot fairly schedule against capacity
    # it does not control.
    def classify_backend_kind(backend)
      return "swarm" if backend.identifier.to_s == "swarm"
      return "remote" if backend.respond_to?(:remote?) && backend.remote?
      return "remote" if backend.identifier.to_s.start_with?("remote")

      "local"
    end

    # Reports whether the connected Docker daemon is shared infrastructure
    # that may host unrelated workloads from other tenants or projects.
    #
    # Local sockets are private. The Swarm backend reports as not-remote
    # because it manages its own cluster from the manager node's view.
    # Everything else (remote Docker endpoints, mismatched identifiers)
    # is treated as shared by default — the safest possible answer for
    # an auto-capacity policy that should not schedule against capacity
    # it does not control.
    def classify_backend_shared(backend)
      kind = classify_backend_kind(backend)
      return false if kind == "local" || kind == "swarm"

      true
    end

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
      inventory = docker_container_inventory
      system_info = docker_info
      references = inventory.build_references
      buckets = deep_dup_buckets
      degraded_reasons = []
      sampling_deadline = monotonic_now + DOCKER_SAMPLING_BUDGET
      running_containers = inventory.list_running_containers(timeout: DOCKER_LIST_TIMEOUT)

      results = ConcurrentStatsSampler.call(
        containers: running_containers,
        monotonic_deadline: sampling_deadline,
        per_container_timeout: DOCKER_CONTAINER_TIMEOUT
      ) { |container| backend.container_stats(container, stream: false) }

      results.each do |result|
        classification = inventory.classify_container(container: result.container, references:)

        if result.skipped
          degraded_reasons << "container_sampling_budget_exceeded"
          accumulate_bucket(buckets.fetch(classification), memory_bytes: 0, cpu_percent: 0.0)
          next
        end

        if result.error
          Rails.logger.warn(
            message: "container_manager.docker_stats_sample_failed",
            backend_identifier: backend.identifier,
            error_class: result.error.class.name,
            error_message: result.error.message
          )
          degraded_reasons << "container_sample_failed"
          accumulate_bucket(buckets.fetch(classification), memory_bytes: 0, cpu_percent: 0.0)
          next
        end

        parsed = Containers::DockerStatsParser.parse_stats(result.raw_stats)
        accumulate_bucket(
          buckets.fetch(classification),
          memory_bytes: parsed.fetch(:memory_bytes, 0).to_i,
          cpu_percent: parsed.fetch(:cpu_percent, 0.0).to_f.round(2)
        )
      end

      # A fully successful sample only reflects the container list as it
      # existed before sampling started. Widening the sampling budget also
      # widened the window in which a new agent-run, chat-session, or MCP
      # sidecar container can start without ever being measured -- silently
      # overstating available_memory_bytes to Capacity::Policy. Re-listing
      # after sampling is cheap (bounded by DOCKER_LIST_TIMEOUT) and catches
      # that drift before a stale-but-confident snapshot reaches admission.
      if degraded_reasons.empty?
        drift_check = container_list_drift_during_sampling(inventory, running_containers)
        if drift_check[:changed]
          log_container_list_drift(
            original_container_count: running_containers.size,
            drift_check: drift_check
          )
          degraded_reasons << "container_list_changed_during_sampling"
        end
      end

      available_memory_bytes = degraded_reasons.empty? ? remaining_memory(system_info: system_info, buckets: buckets) : 0

      Snapshot.new(
        backend_identifier: backend.identifier,
        backend_kind: classify_backend_kind(backend),
        backend_shared: classify_backend_shared(backend),
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

    def container_list_drift_during_sampling(inventory, original_containers)
      current_containers = inventory.list_running_containers(timeout: DOCKER_LIST_TIMEOUT)
      current_ids = current_containers.map(&:id).to_set
      original_ids = original_containers.map(&:id).to_set
      return { changed: true, current_container_count: current_containers.size } if (current_ids - original_ids).any?

      { changed: false }
    rescue Timeout::Error, Docker::Error::DockerError, Docker::Error::ExconError, Excon::Error => error
      {
        changed: true,
        current_container_count: nil,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    def log_container_list_drift(original_container_count:, drift_check:)
      payload = {
        message: "container_manager.container_list_changed_during_sampling",
        backend_identifier: backend.identifier,
        original_container_count: original_container_count,
        current_container_count: drift_check[:current_container_count]
      }
      if drift_check[:error_class]
        payload[:error_class] = drift_check[:error_class]
        payload[:error_message] = drift_check[:error_message]
      end

      Rails.logger.warn(payload)
    end

    def docker_container_inventory
      @docker_container_inventory ||= DockerContainerInventory.new(backend: backend)
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
          backend_kind: cached_snapshot.backend_kind,
          backend_shared: cached_snapshot.backend_shared,
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
          backend_kind: classify_backend_kind(backend),
          backend_shared: classify_backend_shared(backend),
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
