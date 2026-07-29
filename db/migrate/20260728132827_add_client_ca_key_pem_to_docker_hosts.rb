# frozen_string_literal: true

class AddClientCaKeyPemToDockerHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :docker_hosts, :client_ca_key_pem, :text,
      comment: "Encrypted CA private key PEM retained when Paid must generate a matching remote Docker server certificate."
  end
end
