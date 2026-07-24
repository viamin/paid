# frozen_string_literal: true

module Projects
  class DockerHostPreferencesController < ApplicationController
    include DockerHostsIndexPage

    before_action :set_project

    def update
      authorize @project, :update?

      if @project.update(project_docker_host_preference_params)
        redirect_to docker_hosts_path, notice: "Project Docker host preference updated for #{@project.name}."
      else
        @tenant_setting = current_account.tenant_setting!
        load_docker_hosts_index_data
        existing_index = @projects.index { |project| project.id == @project.id }
        @projects[existing_index] = @project if existing_index
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
