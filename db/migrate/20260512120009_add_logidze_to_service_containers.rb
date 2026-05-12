# frozen_string_literal: true

class AddLogidzeToServiceContainers < ActiveRecord::Migration[8.1]
  def change
    add_column :service_containers, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_service_containers, on: :service_containers
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_service_containers" on "service_containers";
        SQL
      end
    end
  end
end
