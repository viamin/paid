# frozen_string_literal: true

module Containers
  class PoolManager
    DEFAULT_TARGET_SIZE = 0
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_001
    RECONNECT_OPTIONS = %i[timeout_seconds].freeze
    SUPPORTED_ACQUIRE_OPTIONS = (RECONNECT_OPTIONS + %i[image]).freeze

    def self.enabled?
      target_size.positive?
    end

    def self.target_size(env = ENV)
      Integer(env.fetch("PAID_CONTAINER_POOL_SIZE", DEFAULT_TARGET_SIZE)).clamp(0, 20)
    rescue ArgumentError
      DEFAULT_TARGET_SIZE
    end

    def self.cleanup_claimed_container(agent_run:, force: false)
      # Scoped by container_id, not just agent_run: if the run has since been
      # re-dispatched (e.g. a stale-snapshot cleanup racing with
      # ExecutionControls::RunImpact#resume_parked_runs!), a newly claimed
      # entry can share the same agent_run association with a different
      # container_id. Matching on both prevents tearing down that new entry.
      entry = ContainerPoolEntry.claimed.find_by(agent_run: agent_run, container_id: agent_run.container_id)
      return false unless entry

      # @container_host is intentionally ignored by remove_entry — it resolves
      # the backend from the entry's own container_host, so we do not need to
      # pass or know the local backend here. Construction without container_host
      # keeps @container_host = Containers.backend.identifier for callers that
      # read it (e.g. tests asserting default scoping), but remove_entry never
      # consults it.
      new(project: agent_run.project).remove_entry(entry, force: force)
      true
    end

    def self.metrics(projects:)
      scope = ContainerPoolEntry.where(project_id: projects.select(:id))
      counts = scope.group(:status).count

      {
        warm: counts["warm"].to_i,
        warming: counts["warming"].to_i,
        claimed: counts["claimed"].to_i,
        error: counts["error"].to_i,
        target: effective_target_size(projects: projects)
      }
    end

    def self.effective_target_size(projects:, backend_count: Containers.all_backends.count)
      active_projects = projects.active.count
      target_size * active_projects * backend_count
    end

    # Acquire a per-project PostgreSQL advisory lock for the duration of the
    # yielded block. Holds the same lock across multi-host iterations so a
    # competing replenishment triggered by PoolReplenishmentJob.perform_later
    # from within `acquire` cannot interleave with the next host's pass.
    def self.with_project_replenishment_lock(project)
      connection = ActiveRecord::Base.connection
      lock_key = project.id % 2_147_483_647
      raw_connection = connection.raw_connection
      raw_connection.exec_params(ADVISORY_LOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
      yield
    ensure
      raw_connection&.exec_params(ADVISORY_UNLOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
    end

    def initialize(project:, target_size: self.class.target_size, container_host: nil)
      @project = project
      @target_size = target_size
      @container_host = container_host.presence || Containers.backend.identifier
    end

    def acquire(agent_run:, container_host: nil, **options)
      return unless enabled_for?(agent_run)
      return unless pool_compatible_options?(options)

      entry = claim_entry(agent_run, options: options, container_host: container_host)
      return unless entry

      unless container_running?(entry.container_id, backend: Containers.backend_for(entry.container_host))
        remove_error_entry(entry, "warm container is not running")
        return
      end

      service = Provision.reconnect(
        agent_run: agent_run,
        container_id: entry.container_id,
        workspace_volume: entry.workspace_volume,
        pool_entry: entry,
        **options.slice(*RECONNECT_OPTIONS)
      )
      PoolReplenishmentJob.perform_later(project.id)
      Provision::Result.success(
        container_id: entry.container_id,
        container_host: entry.container_host,
        service: service,
        pool_entry_id: entry.id
      )
    rescue Provision::ProvisionError => e
      remove_error_entry(entry, e.message) if entry
      nil
    end

    def replenish
      self.class.with_project_replenishment_lock(project) do
        replenish_unlocked
      end
    end

    # Replenishes the pool for the current project/container_host without
    # acquiring the per-project advisory lock. Callers that already hold the
    # lock (e.g. PoolReplenishmentJob iterating across all configured backends)
    # must use this to avoid releasing the lock between host iterations and
    # letting a competing replenishment slip in via PoolReplenishmentJob's
    # GoodJob total_limit: 1 concurrency guard racing with itself.
    def replenish_unlocked
      cleanup_claimed_finished_runs
      cleanup_stale_pool_entries
      trim_excess_warm_entries
      missing_count.times { warm_one }
    end

    def remove_entry(entry, force: false)
      backend = Containers.backend_for(entry.container_host)
      remove_container(entry.container_id, force: force, backend: backend)
      remove_volume(entry.workspace_volume, backend: backend, host: entry.container_host)
      entry.destroy!
    end

    private

    attr_reader :project, :target_size, :container_host

    # Image warmed and claimed for this project's pool. Resolves from the
    # project's language profile (RDR-046 / POLYGLOT-TEST-004) so a warmed
    # container matches the image a run will actually request via
    # +Containers::Provision+. Falls back to the base image when the project
    # has no extended runtime needs.
    def resolved_image
      Containers::ImageResolver.resolve(project)
    end

    def enabled_for?(agent_run)
      target_size.positive? &&
        agent_run.worktree_path.blank? &&
        agent_run.service_container_ids.blank? &&
        run_network_name(agent_run) == pool_network_name
    end

    def pool_compatible_options?(options)
      (options.keys - SUPPORTED_ACQUIRE_OPTIONS).empty?
    end

    def claim_entry(agent_run, options:, container_host:)
      ContainerPoolEntry.transaction do
        entry = warm_scope(options: options, container_host: container_host).lock("FOR UPDATE SKIP LOCKED").order(:warmed_at, :id).first
        next unless entry

        entry.update!(status: "claimed", agent_run: agent_run, claimed_at: Time.current)
        entry
      end
    end

    def warm_scope(options:, container_host:)
      scope = project.container_pool_entries.warm.where(
        image: options.fetch(:image, resolved_image),
        network: pool_network_name
      )
      return scope if container_host.blank?

      # RDR-048 (#2947): scope warm claims to the planned host so a run
      # admitted against host A never claims a warm container on host B.
      # Without this filter, warm-pool acquisition would override explicit
      # placement and could exceed the configured per-host ceiling, since
      # ceiling accounting counts runs by their persisted container_host.
      scope.where(container_host: container_host)
    end

    def missing_count
      [ target_size - current_pool_count, 0 ].max
    end

    def current_pool_count
      current_pool_entries.count
    end

    def warm_one
      entry = project.container_pool_entries.create!(
        status: "warming",
        image: resolved_image,
        network: pool_network_name,
        container_host: container_host,
        workspace_volume: "paid-pool-workspace-#{SecureRandom.hex(12)}"
      )
      provision_entry(entry)
    end

    def provision_entry(entry)
      service = Provision.new(
        project: project,
        pool_entry: entry,
        workspace_volume: entry.workspace_volume,
        image: entry.image
      )
      result = service.provision
      entry.update!(
        container_id: result[:container_id],
        container_host: result[:container_host],
        status: "warm",
        warmed_at: Time.current,
        last_error: nil
      )
      entry
    rescue ApplicationJob::PerformTimeoutError
      raise
    rescue StandardError => e
      remove_failed_provision(entry, service, e.message)
      nil
    end

    def cleanup_claimed_finished_runs
      project.container_pool_entries.claimed.where(container_host: container_host).includes(:agent_run).find_each do |entry|
        next if entry.agent_run&.container_retained?
        next if entry.agent_run&.status.in?(AgentRun::UNFINISHED_STATUSES)

        remove_entry(entry, force: true)
      end
    end

    def cleanup_stale_pool_entries
      stale_warm_pool_entries.find_each do |entry|
        remove_entry(entry, force: true)
      end

      project.container_pool_entries.stale_warming.where(container_host: container_host).find_each do |entry|
        remove_error_entry(entry, "warming container did not finish before stale threshold")
      end

      current_pool_entries.warm.find_each do |entry|
        remove_error_entry(entry, "warm container is not running") unless container_running?(entry.container_id, backend: Containers.backend_for(entry.container_host))
      end
    end

    def trim_excess_warm_entries
      excess_count = [ current_pool_count - target_size, 0 ].max
      return unless excess_count.positive?

      current_pool_entries.warm.order(:warmed_at, :id).limit(excess_count).each do |entry|
        remove_entry(entry, force: true)
      end
    end

    def current_pool_entries
      project.container_pool_entries.where(
        image: resolved_image,
        network: pool_network_name,
        container_host: container_host
      ).where(
        ContainerPoolEntry.arel_table[:status].eq("warm").or(
          ContainerPoolEntry.arel_table[:status].eq("warming").and(
            ContainerPoolEntry.arel_table[:created_at].gteq(ContainerPoolEntry::WARMING_STALE_AFTER.ago)
          )
        )
      )
    end

    def stale_warm_pool_entries
      project.container_pool_entries.warm.where(container_host: container_host).where.not(
        image: resolved_image,
        network: pool_network_name
      )
    end

    def container_running?(container_id, backend: Containers.backend)
      container = backend.get_container(container_id)
      container.info.dig("State", "Running") == true
    rescue Docker::Error::DockerError
      false
    end

    def remove_container(container_id, force:, backend: Containers.backend)
      return if container_id.blank?

      container = backend.get_container(container_id)
      backend.stop_container(container, timeout: force ? 0 : 10) if container.info.dig("State", "Running")
      backend.delete_container(container, force: force, v: true)
    rescue Docker::Error::NotFoundError
      nil
    rescue Docker::Error::DockerError => e
      Rails.logger.warn(message: "container_manager.pool_container_remove_failed", container_id: container_id, error: e.message)
    end

    def remove_volume(volume_name, backend: Containers.backend, host: nil)
      backend.delete_volume(backend.get_volume(volume_name, host: host))
    rescue Docker::Error::NotFoundError
      nil
    rescue Docker::Error::DockerError => e
      Rails.logger.warn(message: "container_manager.pool_volume_remove_failed", volume_name: volume_name, error: e.message)
    end

    def mark_error(entry, message)
      entry.update!(status: "error", last_error: message)
      Rails.logger.warn(
        message: "container_manager.pool_entry_error",
        project_id: project.id,
        container_pool_entry_id: entry.id,
        container_host: entry.container_host,
        error: message
      )
    end

    def remove_error_entry(entry, message)
      mark_error(entry, message)
      remove_entry(entry, force: true)
    end

    def remove_failed_provision(entry, service, message)
      mark_error(entry, message)
      cleanup_service(service)
      remove_entry(entry, force: true)
    end

    def cleanup_service(service)
      service&.cleanup(force: true)
    rescue StandardError
      nil
    end

    def pool_network_name
      @pool_network_name ||= Provision.new(project: project).network_name
    end

    def run_network_name(agent_run)
      Provision.new(agent_run: agent_run).network_name
    end
  end
end
