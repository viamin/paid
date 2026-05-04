# frozen_string_literal: true

class McpServerDefinitionsController < ApplicationController
  before_action :set_mcp_server_definition, only: [ :show, :edit, :update, :destroy ]

  def index
    authorize McpServerDefinition
    @mcp_server_definitions = policy_scope(McpServerDefinition).includes(:account).order(created_at: :desc)
  end

  def show
    authorize @mcp_server_definition
  end

  def new
    @mcp_server_definition = current_account.mcp_server_definitions.build
    authorize @mcp_server_definition
  end

  def create
    @mcp_server_definition = current_account.mcp_server_definitions.build(mcp_server_definition_params)
    authorize @mcp_server_definition

    if @mcp_server_definition.save
      redirect_to @mcp_server_definition, notice: "MCP server definition was successfully created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @mcp_server_definition
  end

  def update
    authorize @mcp_server_definition

    if @mcp_server_definition.update(mcp_server_definition_params)
      redirect_to @mcp_server_definition, notice: "MCP server definition was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @mcp_server_definition
    @mcp_server_definition.destroy!
    redirect_to mcp_server_definitions_path, notice: "MCP server definition was successfully deleted."
  end

  private

  def set_mcp_server_definition
    @mcp_server_definition = policy_scope(McpServerDefinition).find(params[:id])
  end

  def mcp_server_definition_params
    params.require(:mcp_server_definition).permit(:name, :transport, :install_type, :command, :args_json, :url, :image, :env_json, :enabled, :metadata_json)
  end
end
