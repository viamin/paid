# frozen_string_literal: true

class DockerHostsController < ApplicationController
  before_action :set_tenant_setting, only: [ :index ]
  before_action :set_docker_host, only: [ :show, :edit, :update, :disable ]

  def index
    authorize current_account, :show?
    load_index_data
    @docker_host = current_account.docker_hosts.new(
      backend_type: "local",
      callback_url: default_callback_url
    )
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
    @docker_host = current_account.docker_hosts.new(docker_host_params)

    if @docker_host.save
      redirect_to docker_host_path(@docker_host), notice: "Docker host created."
    else
      load_index_data
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
    @docker_host = policy_scope(DockerHost).where(account: current_account).find(params[:id])
  end

  def load_index_data
    @docker_hosts = policy_scope(DockerHost).where(account: current_account).ordered
    @projects = current_account.projects.order(:name)
    @active_runs_by_host = AgentRun.joins(:project)
      .where(projects: { account_id: current_account.id }, status: AgentRun::UNFINISHED_STATUSES)
      .group(:container_host)
      .count
  end

  def recent_runs_for(docker_host)
    AgentRun.joins(:project)
      .where(projects: { account_id: current_account.id }, container_host: docker_host.identifier)
      .includes(:project, :issue)
      .order(created_at: :desc)
      .limit(10)
  end

  def default_callback_url
    "/health/services"
  end

  def docker_host_params
    params.require(:docker_host).permit(
      :display_name,
      :identifier,
      :backend_type,
      :endpoint,
      :callback_url,
      :image_tag,
      :fallback_eligible,
      :manual_concurrency_limit,
      :enabled,
      :readiness_status,
      :failing_check,
      :last_checked_at,
      :last_ready_at,
      :last_error,
      :daemon_architecture,
      :daemon_summary,
      :image_status,
      :required_network_status
    )
  end
end
