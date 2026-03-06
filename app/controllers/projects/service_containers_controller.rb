# frozen_string_literal: true

module Projects
  class ServiceContainersController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :update?

      service_container = find_service_container
      return if service_container.nil?

      project_service_container = @project.project_service_containers.find_or_create_by!(service_container: service_container)

      if project_service_container.previously_new_record?
        redirect_to edit_project_path(@project), notice: "Service container was added to the project."
      else
        redirect_to edit_project_path(@project), alert: "Service container is already associated with this project."
      end
    rescue ActiveRecord::RecordNotUnique
      redirect_to edit_project_path(@project), alert: "Service container is already associated with this project."
    end

    def destroy
      authorize @project, :update?

      project_service_container = find_project_service_container
      return if project_service_container.nil?

      project_service_container.destroy!

      redirect_to edit_project_path(@project), notice: "Service container was removed from the project."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def find_service_container
      ServiceContainer.find(params[:service_container_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to edit_project_path(@project), alert: "Service container not found."
      nil
    end

    def find_project_service_container
      @project.project_service_containers.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to edit_project_path(@project), alert: "Service container not found."
      nil
    end
  end
end
