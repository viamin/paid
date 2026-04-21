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
      entry = ContainerPoolEntry.claimed.find_by(agent_run: agent_run)
      return false unless entry

      new(project: agent_run.project).remove_entry(entry, force: force)
      true
    end

    def self.metrics(projects:)
      scope = ContainerPoolEntry.where(project_id: projects.select(:id))
      active_projects = projects.active.count

      {
        warm: scope.warm.count,
        warming: scope.warming.count,
        claimed: scope.claimed.count,
        error: scope.errored.count,
        target: target_size * active_projects
      }
    end

    def initialize(project:, target_size: self.class.target_size)
      @project = project
      @target_size = target_size
    end

    def acquire(agent_run:, **options)
      return unless enabled_for?(agent_run)
      return unless pool_compatible_options?(options)

      entry = claim_entry(agent_run, options: options)
      return unless entry

      unless container_running?(entry.container_id)
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
      Provision::Result.success(container_id: entry.container_id, service: service, pool_entry_id: entry.id)
    rescue Provision::ProvisionError => e
      remove_error_entry(entry, e.message) if entry
      nil
    end

    def replenish
      with_project_replenishment_lock do
        cleanup_claimed_finished_runs
        cleanup_stale_pool_entries
        trim_excess_warm_entries
        missing_count.times { warm_one }
      end
    end

    def remove_entry(entry, force: false)
      remove_container(entry.container_id, force: force)
      remove_volume(entry.workspace_volume)
      entry.destroy!
    end

    private

    attr_reader :project, :target_size

    def enabled_for?(agent_run)
      target_size.positive? &&
        agent_run.worktree_path.blank? &&
        agent_run.service_container_ids.blank? &&
        run_network_name(agent_run) == pool_network_name
    end

    def pool_compatible_options?(options)
      (options.keys - SUPPORTED_ACQUIRE_OPTIONS).empty?
    end

    def claim_entry(agent_run, options:)
      ContainerPoolEntry.transaction do
        entry = warm_scope(options: options).lock("FOR UPDATE SKIP LOCKED").order(:warmed_at, :id).first
        next unless entry

        entry.update!(status: "claimed", agent_run: agent_run, claimed_at: Time.current)
        entry
      end
    end

    def warm_scope(options:)
      project.container_pool_entries.warm.where(
        image: options.fetch(:image, Provision::DEFAULTS[:image]),
        network: pool_network_name
      )
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
        image: Provision::DEFAULTS[:image],
        network: pool_network_name,
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
      entry.update!(container_id: result[:container_id], status: "warm", warmed_at: Time.current, last_error: nil)
      entry
    rescue StandardError => e
      remove_failed_provision(entry, service, e.message)
      nil
    end

    def cleanup_claimed_finished_runs
      project.container_pool_entries.claimed.includes(:agent_run).find_each do |entry|
        next if entry.agent_run&.status.in?(AgentRun::UNFINISHED_STATUSES)

        remove_entry(entry, force: true)
      end
    end

    def cleanup_stale_pool_entries
      project.container_pool_entries.stale_warming.find_each do |entry|
        remove_error_entry(entry, "warming container did not finish before stale threshold")
      end

      current_pool_entries.warm.find_each do |entry|
        remove_error_entry(entry, "warm container is not running") unless container_running?(entry.container_id)
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
        image: Provision::DEFAULTS[:image],
        network: pool_network_name
      ).where(
        ContainerPoolEntry.arel_table[:status].eq("warm").or(
          ContainerPoolEntry.arel_table[:status].eq("warming").and(
            ContainerPoolEntry.arel_table[:created_at].gteq(ContainerPoolEntry::WARMING_STALE_AFTER.ago)
          )
        )
      )
    end

    def with_project_replenishment_lock
      execute_lock_sql(ADVISORY_LOCK_SQL)
      yield
    ensure
      execute_lock_sql(ADVISORY_UNLOCK_SQL)
    end

    def project_lock_key
      project.id % 2_147_483_647
    end

    def execute_lock_sql(sql)
      ActiveRecord::Base.connection.raw_connection.exec_params(sql, [ LOCK_NAMESPACE, project_lock_key ])
    end

    def container_running?(container_id)
      container = Docker::Container.get(container_id)
      container.info.dig("State", "Running") == true
    rescue Docker::Error::DockerError
      false
    end

    def remove_container(container_id, force:)
      return if container_id.blank?

      container = Docker::Container.get(container_id)
      container.stop(timeout: force ? 0 : 10) if container.info.dig("State", "Running")
      container.delete(force: force, v: true)
    rescue Docker::Error::NotFoundError
      nil
    rescue Docker::Error::DockerError => e
      Rails.logger.warn(message: "container_manager.pool_container_remove_failed", container_id: container_id, error: e.message)
    end

    def remove_volume(volume_name)
      Docker::Volume.get(volume_name).remove
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
