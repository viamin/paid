# frozen_string_literal: true

module Activities
  class LoadFeatureFlagsActivity < BaseActivity
    activity_name "LoadFeatureFlags"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { flags: {}, project_missing: true } unless project

      { flags: FeatureFlags.snapshot(project: project), project_missing: false }
    end
  end
end
