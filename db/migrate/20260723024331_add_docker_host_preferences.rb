# frozen_string_literal: true

class AddDockerHostPreferences < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:tenant_settings, :preferred_docker_host_identifier)
      add_column :tenant_settings, :preferred_docker_host_identifier, :string,
        comment: "Account-wide preferred Docker host identifier for manual placement defaults."
    end

    return if column_exists?(:tenant_settings, :docker_host_fallback_behavior)

    add_column :tenant_settings, :docker_host_fallback_behavior, :string, null: false, default: "disabled",
      comment: "Fallback behavior when the preferred Docker host is unavailable: disabled or first_healthy."
  end
end
