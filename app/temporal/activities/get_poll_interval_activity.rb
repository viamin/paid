# frozen_string_literal: true

module Activities
  # Retrieves the configured poll interval for a project.
  #
  # Extracted as an activity because workflows cannot perform I/O directly.
  class GetPollIntervalActivity < BaseActivity
    def execute(project_id:)
      project = Project.find(project_id)
      { poll_interval_seconds: project.poll_interval_seconds }
    end
  end
end
