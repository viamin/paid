# frozen_string_literal: true

class AddContainerHostToServiceContainers < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:service_containers, :container_host)

    add_column :service_containers, :container_host, :string,
      limit: 64,
      comment: "Container backend host identifier that currently owns the running service container."
  end
end
