# frozen_string_literal: true

class DockerHostsController < ApplicationController
  include DockerHostsIndexPage

  before_action :set_tenant_setting, only: [ :index ]
  before_action :set_docker_host, only: [ :show, :edit, :update, :disable ]

  def index
    authorize current_account, :show?
    load_docker_hosts_index_data
  end

  def show
    authorize current_account, :show?
    @recent_runs = recent_runs_for(@docker_host)
  end

  def edit
    authorize current_account, :update?
  end

  def create
    authorize current_account, :update?
    new_host = current_account.docker_hosts.new(docker_host_params)

    if new_host.save
      redirect_to docker_host_path(new_host), notice: "Docker host created."
    else
      load_docker_hosts_index_data
      @docker_host = new_host
      @tenant_setting = current_account.tenant_setting!
      flash.now[:alert] = "Unable to create Docker host."
      render :index, status: :unprocessable_content
    end
  end

  def update
    authorize current_account, :update?

    if @docker_host.update(docker_host_params)
      redirect_to docker_host_path(@docker_host), notice: "Docker host updated."
    else
      flash.now[:alert] = "Unable to update Docker host."
      render :edit, status: :unprocessable_content
    end
  end

  def disable
    authorize current_account, :update?
    @docker_host.disable!
    redirect_to docker_host_path(@docker_host), notice: "Docker host disabled. Historical run ownership is preserved."
  end

  private

  def set_tenant_setting
    @tenant_setting = current_account.tenant_setting!
  end

  def set_docker_host
    @docker_host = policy_scope(DockerHost).find(params[:id])
  end

  def recent_runs_for(docker_host)
    AgentRun.joins(:project)
      .where(projects: { account_id: current_account.id }, container_host: docker_host.identifier)
      .includes(:project, :issue)
      .order(created_at: :desc)
      .limit(10)
  end

  def docker_host_params
    permitted = [
      :display_name,
      :backend_type,
      :endpoint,
      :callback_url,
      :image_tag,
      :fallback_eligible,
      :manual_concurrency_limit,
      :enabled
    ]
    permitted.unshift(:identifier) unless action_name == "update"

    params.require(:docker_host).permit(*permitted)
  end
end
