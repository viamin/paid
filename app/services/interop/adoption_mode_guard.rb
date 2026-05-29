# frozen_string_literal: true

module Interop
  class AdoptionModeGuard
    MODE_PERMISSIONS = {
      "observe_only" => %i[view_metrics view_external_runs view_connector_events],
      "advisory" => %i[view_metrics view_external_runs view_connector_events ingest_external_runs receive_connector_events import_config],
      "review_only" => %i[view_metrics view_external_runs view_connector_events ingest_external_runs receive_connector_events import_config review_runs],
      "full_execution" => %i[view_metrics view_external_runs view_connector_events ingest_external_runs receive_connector_events import_config review_runs execute_runs manage_connectors]
    }.freeze

    def self.call(...)
      new(...).call
    end

    def self.enforce!(project:, action:)
      return true if call(project:, action:)

      raise ArgumentError, "#{action} is not permitted when adoption_mode is #{project.adoption_mode}"
    end

    def initialize(project:, action:)
      @project = project
      @action = action.to_sym
    end

    def call
      if permitted?
        true
      else
        Rails.logger.info(
          message: "interop.adoption_mode_blocked",
          project_id: project.id,
          adoption_mode: project.adoption_mode,
          action: action
        )
        false
      end
    end

    def permitted?
      allowed_actions.include?(action)
    end

    def self.permitted_actions_for(mode)
      MODE_PERMISSIONS.fetch(mode, [])
    end

    private

    attr_reader :project, :action

    def allowed_actions
      MODE_PERMISSIONS.fetch(project.adoption_mode, [])
    end
  end
end
