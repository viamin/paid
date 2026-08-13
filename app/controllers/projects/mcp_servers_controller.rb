# frozen_string_literal: true

module Projects
  class McpServersController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :update?

      mcp_server_definition = find_mcp_server_definition
      return unless mcp_server_definition

      project_mcp_server = @project.project_mcp_servers.find_or_create_by!(mcp_server_definition: mcp_server_definition)

      if project_mcp_server.previously_new_record?
        redirect_to edit_project_path(@project), notice: "MCP server was added to the project."
      else
        redirect_to edit_project_path(@project), alert: "MCP server is already associated with this project."
      end
    rescue ActiveRecord::RecordNotUnique
      redirect_to edit_project_path(@project), alert: "MCP server is already associated with this project."
    end

    def destroy
      authorize @project, :update?

      project_mcp_server = find_project_mcp_server
      return unless project_mcp_server

      project_mcp_server.destroy!
      redirect_to edit_project_path(@project), notice: "MCP server was removed from the project."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def find_mcp_server_definition
      policy_scope(McpServerDefinition).find(params[:mcp_server_definition_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to edit_project_path(@project), alert: "MCP server definition not found."
      nil
    end

    def find_project_mcp_server
      @project.project_mcp_servers.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to edit_project_path(@project), alert: "MCP server not found."
      nil
    end
  end
end
