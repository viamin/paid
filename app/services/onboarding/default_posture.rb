# frozen_string_literal: true

module Onboarding
  # Proposes the default project posture (RDR-066) during onboarding: the
  # human-led feature factory profile, presented as a reviewable settings
  # plan before anything is applied.
  # @spec FEATURE-APPROVAL-004
  module DefaultPosture
    CHOICE_HUMAN_LED = "human_led_feature_factory"
    CHOICE_STANDARD = "standard"
    CHOICES = [ CHOICE_STANDARD, CHOICE_HUMAN_LED ].freeze

    module_function

    def profile
      Configuration::Profiles::HumanLedFeatureFactory
    end

    # The project the posture proposal targets: the first project created
    # during onboarding, preferring the recorded step metadata.
    def first_project(account)
      step = account.onboarding_steps.find_by(step: "first_project")
      project_id = step&.metadata&.dig("project_id")
      return account.projects.find_by(id: project_id) if project_id

      account.projects.order(:created_at).first
    end

    def plan_for(project:, actor:, overrides: {})
      Configuration::Profiles::Planner.call(
        profile: profile,
        project: project,
        actor: actor,
        overrides: overrides
      )
    end
  end
end
