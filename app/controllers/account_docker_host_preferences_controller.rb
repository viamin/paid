# frozen_string_literal: true

class AccountDockerHostPreferencesController < ApplicationController
  def update
    authorize current_account, :update?
    @tenant_setting = current_account.tenant_setting!

    if @tenant_setting.update(account_docker_host_preferences_params)
      redirect_to docker_hosts_path, notice: "Account Docker host preferences updated."
    else
      @docker_hosts = current_account.docker_hosts.ordered
      @projects = current_account.projects.order(:name)
      @active_runs_by_host = AgentRun.joins(:project)
        .where(projects: { account_id: current_account.id }, status: AgentRun::UNFINISHED_STATUSES)
        .group(:container_host)
        .count
      @docker_host = current_account.docker_hosts.new(
        backend_type: "local",
        callback_url: "/health/services"
      )
      flash.now[:alert] = "Unable to save account Docker host preferences."
      render "docker_hosts/index", status: :unprocessable_content
    end
  end

  private

  def account_docker_host_preferences_params
    params.require(:tenant_setting).permit(:preferred_docker_host_identifier, :docker_host_fallback_behavior)
  end
end
