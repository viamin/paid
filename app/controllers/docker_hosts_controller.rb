# frozen_string_literal: true

class DockerHostsController < ApplicationController
  include DockerHostsIndexPage

  before_action :set_tenant_setting, only: [ :index ]
  before_action :set_docker_host, only: [ :show, :edit, :update, :disable, :setup, :update_setup, :setup_helper ]

  def index
    authorize current_account, :show?
    load_docker_hosts_index_data
  end

  def show
    authorize current_account, :show?
    @recent_runs = recent_runs_for(@docker_host)
    @capacity_snapshot = capacity_snapshot_for(@docker_host)
  end

  def edit
    authorize current_account, :update?
  end

  def setup
    authorize current_account, :update?
    load_setup_guide
  end

  def create
    authorize current_account, :update?
    new_host = current_account.docker_hosts.new(docker_host_params)

    if new_host.save
      if new_host.remote?
        redirect_to setup_docker_host_path(new_host), notice: "Docker host created. Continue the remote setup guide."
      else
        redirect_to docker_host_path(new_host), notice: "Docker host created."
      end
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

  def update_setup
    authorize current_account, :update?

    if persist_setup_fields
      redirect_to setup_docker_host_path(@docker_host), notice: "Remote setup details updated."
    else
      load_setup_guide
      flash.now[:alert] = "Unable to update remote setup details."
      render :setup, status: :unprocessable_content
    end
  end

  def setup_helper
    authorize current_account, :update?
    unless persist_setup_fields
      load_setup_guide
      flash.now[:alert] = "Unable to update remote setup details."
      return render :setup, status: :unprocessable_content
    end

    result = DockerHosts::SetupActionRunner.call(
      host: @docker_host,
      action: params[:helper_action],
      params: setup_helper_params
    )

    redirect_to setup_docker_host_path(@docker_host), result.success? ? { notice: result.message } : { alert: result.message }
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

  def capacity_snapshot_for(docker_host)
    runtime_host = Containers.host_registry.host(docker_host.identifier)
    return unless runtime_host

    Capacity::DockerSnapshot.call(backend: runtime_host.backend)
  rescue StandardError
    nil
  end

  def docker_host_params
    permitted = [
      :display_name,
      :backend_type,
      :endpoint,
      :callback_url,
      :image_tag,
      :required_network_name,
      :fallback_eligible,
      :manual_concurrency_limit,
      :enabled
    ]
    permitted.unshift(:identifier) unless action_name == "update"

    params.require(:docker_host).permit(*permitted)
  end

  def load_setup_guide
    @setup_guide = DockerHosts::SetupGuide.new(@docker_host)
    @setup_step_rows = @setup_guide.step_rows
    @setup_manual_instructions = @setup_guide.manual_instructions
    @setup_command_snippets = @setup_guide.command_snippets
  end

  def persist_setup_fields
    metadata = @docker_host.metadata.deep_dup
    metadata["setup"] ||= {}
    metadata["setup"]["profile"] = setup_host_profile
    @docker_host.assign_attributes(setup_params.merge(metadata: metadata))
    @docker_host.save
  end

  def setup_params
    params.fetch(:docker_host, {}).permit(
      :display_name,
      :endpoint,
      :callback_url,
      :required_network_name,
      :image_tag,
      :manual_concurrency_limit
    )
  end

  def setup_host_profile
    params[:setup_profile].to_s.presence || @docker_host.setup_profile
  end

  def setup_helper_params
    params.permit(
      :client_common_name,
      :client_ca_pem,
      :client_certificate_pem,
      :client_private_key_pem,
      :server_common_name,
      :server_sans,
      :server_mode,
      :required_network_name,
      :callback_url,
      :allow_network_create,
      :step_key
    )
  end
end
