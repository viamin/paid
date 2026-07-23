# frozen_string_literal: true

module Projects
  class DockerHostPreferencesController < ApplicationController
    before_action :set_project

    def update
      authorize @project, :update?

      if @project.update(project_docker_host_preference_params)
        redirect_to docker_hosts_path, notice: "Project Docker host preference updated for #{@project.name}."
      else
        @tenant_setting = current_account.tenant_setting!
        @docker_hosts = current_account.docker_hosts.ordered
        @projects = current_account.projects.order(:name).to_a
        existing_index = @projects.index { |project| project.id == @project.id }
        @projects[existing_index] = @project if existing_index
        @active_runs_by_host = AgentRun.joins(:project)
          .where(projects: { account_id: current_account.id }, status: AgentRun::UNFINISHED_STATUSES)
          .group(:container_host)
          .count
        @docker_host = current_account.docker_hosts.new(
          backend_type: "local",
          callback_url: "/health/services"
        )
        flash.now[:alert] = "Unable to save project Docker host preference."
        render "docker_hosts/index", status: :unprocessable_content
      end
    end

    private

    def set_project
      @project = policy_scope(Project).where(account: current_account).find(params[:project_id])
    end

    def project_docker_host_preference_params
      params.require(:project).permit(:preferred_docker_host_identifier)
    end
  end
end
