# frozen_string_literal: true

module DockerHostsIndexPage
  extend ActiveSupport::Concern

  private

  def load_docker_hosts_index_data
    @docker_hosts = policy_scope(DockerHost).where(account: current_account).ordered
    @capacity_snapshots_by_host = capacity_snapshots_by_host(@docker_hosts)
    @enabled_docker_host_options = @docker_hosts.select(&:enabled?).map { |host| [ host.display_name, host.identifier ] }
    @projects = current_account.projects
      .includes(account: [ :tenant_setting, :docker_hosts ])
      .order(:name)
    @active_runs_by_host = AgentRun.joins(:project)
      .where(projects: { account_id: current_account.id }, status: AgentRun::UNFINISHED_STATUSES)
      .group(:container_host)
      .count
    @docker_host = current_account.docker_hosts.new(
      backend_type: "local",
      callback_url: "/health/services"
    )
  end

  def capacity_snapshots_by_host(docker_hosts)
    registry = Containers.host_registry

    docker_hosts.each_with_object({}) do |host, snapshots|
      runtime_host = registry.host(host.identifier)
      next unless runtime_host

      snapshots[host.identifier] = Capacity::DockerSnapshot.call(backend: runtime_host.backend)
    rescue StandardError
      next
    end
  end
end
