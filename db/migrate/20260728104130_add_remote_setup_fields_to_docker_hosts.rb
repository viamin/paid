# frozen_string_literal: true

class AddRemoteSetupFieldsToDockerHosts < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:docker_hosts, :required_network_name)
      add_column :docker_hosts, :required_network_name, :string,
        comment: "Docker network name the remote host must provide for disposable agent containers."
    end

    unless column_exists?(:docker_hosts, :client_ca_pem)
      add_column :docker_hosts, :client_ca_pem, :text,
        comment: "Encrypted CA certificate PEM used by Paid when connecting to this remote Docker daemon over TLS."
    end

    unless column_exists?(:docker_hosts, :client_certificate_pem)
      add_column :docker_hosts, :client_certificate_pem, :text,
        comment: "Encrypted client certificate PEM used by Paid when connecting to this remote Docker daemon over TLS."
    end

    unless column_exists?(:docker_hosts, :client_private_key_pem)
      add_column :docker_hosts, :client_private_key_pem, :text,
        comment: "Encrypted client private key PEM used by Paid when connecting to this remote Docker daemon over TLS."
    end

    unless column_exists?(:docker_hosts, :server_certificate_pem)
      add_column :docker_hosts, :server_certificate_pem, :text,
        comment: "Encrypted server certificate PEM generated or uploaded for operator installation on the remote Docker daemon host."
    end

    unless column_exists?(:docker_hosts, :server_private_key_pem)
      add_column :docker_hosts, :server_private_key_pem, :text,
        comment: "Encrypted server private key PEM generated for manual installation on the remote Docker daemon host."
    end

    return if column_exists?(:docker_hosts, :server_csr_pem)

    add_column :docker_hosts, :server_csr_pem, :text,
      comment: "Encrypted server certificate signing request PEM generated for operator submission to their certificate authority."
  end
end
