# frozen_string_literal: true

module Projects
  class MutationTestRequirementsController < ApplicationController
    before_action :set_project

    def update
      authorize @project, :update?

      enabled = params.dig(:mutation_test, :enabled) == "1"
      command = params.dig(:mutation_test, :command).presence ||
        PreCommitRequirement::MUTATION_TEST_DEFAULT_COMMAND
      raw_behavior = params.dig(:mutation_test, :failure_behavior)
      failure_behavior = %w[block warn].include?(raw_behavior) ? raw_behavior : "warn"

      requirement = @project.pre_commit_requirements.find_by(check_type: "mutation_test")

      if requirement
        requirement.update!(enabled: enabled, command: command, failure_behavior: failure_behavior)
      elsif enabled
        @project.pre_commit_requirements.create!(
          account: @project.account,
          name: "mutation_test",
          check_type: "mutation_test",
          command: command,
          failure_behavior: failure_behavior,
          position: 0,
          enabled: true
        )
      end

      redirect_to edit_project_path(@project, anchor: "mutation-testing"),
        notice: "Mutation testing settings saved."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
