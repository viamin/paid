# frozen_string_literal: true

class AccountDockerHostPreferencesController < ApplicationController
  include DockerHostsIndexPage

  def update
    authorize current_account, :update?
    @tenant_setting = current_account.tenant_setting!

    if @tenant_setting.update(account_docker_host_preferences_params)
      redirect_to docker_hosts_path, notice: "Account Docker host preferences updated."
    else
      load_docker_hosts_index_data
      flash.now[:alert] = "Unable to save account Docker host preferences."
      render "docker_hosts/index", status: :unprocessable_content
    end
  end

  private

  def account_docker_host_preferences_params
    params.require(:tenant_setting).permit(:preferred_docker_host_identifier, :docker_host_fallback_behavior)
  end
end
