# frozen_string_literal: true

require "pathname"
require "set"
require "timeout"

module Capacity
  class DockerContainerInventory
    def initialize(backend:)
      @backend = backend
    end

    def list_running_containers(timeout:)
      containers = Timeout.timeout(timeout) do
        backend.list_containers(**backend.capacity_snapshot_list_container_options)
      end

      containers.select { |container| running_container?(container.info) }
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

      return :paid_service_containers if service_container?(labels:, container_id:, references:)
      return :paid_agents if paid_agent?(labels:, container_id:, references:)
      return :paid_control_plane if control_plane_container?(labels:, container_id:, references:)

      :other_docker
    end

    def running_paid_agent_container?(container:, references:)
      labels = container_labels(container.info)
      container_id = container.id

      !mcp_sidecar?(labels:, container_id:, references:) &&
        (labels["paid.agent_run_id"].present? || references.fetch(:agent_container_ids).include?(container_id))
    end

    private

    attr_reader :backend

    def service_container?(labels:, container_id:, references:)
      labels["paid.service_container"] == "true" ||
        references.fetch(:service_container_ids).include?(container_id)
    end

    def paid_agent?(labels:, container_id:, references:)
      labels["paid.agent_run_id"].present? ||
        mcp_sidecar?(labels:, container_id:, references:) ||
        labels["paid.container_pool"] == "true" ||
        references.fetch(:agent_container_ids).include?(container_id)
    end

    def mcp_sidecar?(labels:, container_id:, references:)
      labels["paid.mcp_sidecar"] == "true" ||
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
      return false unless DockerSnapshot::PAID_COMPOSE_SERVICES.include?(compose_service)

      paid_compose_project?(compose_project) || paid_compose_workdir?(compose_workdir)
    end

    def paid_compose_project?(compose_project)
      normalize_compose_project(compose_project) == DockerSnapshot::PAID_COMPOSE_PROJECT
    end

    def paid_compose_workdir?(compose_workdir)
      normalize_compose_workdir(compose_workdir)&.basename&.to_s == DockerSnapshot::PAID_COMPOSE_PROJECT
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
  end
end
