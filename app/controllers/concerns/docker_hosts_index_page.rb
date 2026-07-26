# frozen_string_literal: true

module DockerHostsIndexPage
  extend ActiveSupport::Concern

  private

  def load_docker_hosts_index_data
    @docker_hosts = policy_scope(DockerHost).where(account: current_account).ordered
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
end
