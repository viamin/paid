# frozen_string_literal: true

module Activities
  # Retrieves the configured poll interval for a project.
  #
  # Extracted as an activity because workflows cannot perform I/O directly.
  class GetPollIntervalActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      project = Project.find_by(id: project_id)
      return { poll_interval_seconds: 0, project_missing: true } unless project

      { poll_interval_seconds: project.poll_interval_seconds }
    end
  end
end
