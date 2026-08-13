# frozen_string_literal: true

module PreferredDockerHostIdentifierValidation
  extend ActiveSupport::Concern

  private

  def validate_preferred_docker_host_identifier
    return if preferred_docker_host_identifier.blank?
    return if enabled_docker_host_identifier?(preferred_docker_host_identifier)

    errors.add(:preferred_docker_host_identifier, "must reference an enabled Docker host")
  end

  def enabled_docker_host_identifier?(identifier)
    return false unless account

    docker_hosts = account.docker_hosts
    return docker_hosts.enabled.exists?(identifier: identifier) unless docker_hosts.loaded?

    docker_hosts.any? { |host| host.enabled? && host.identifier == identifier }
  end
end
