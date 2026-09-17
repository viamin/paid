# frozen_string_literal: true

module Onboarding
  # Applies (or declines) the proposed default project posture during the
  # configure_defaults onboarding step. Applying goes through the standard
  # configuration-profile Planner/Applier path so the change is planned,
  # authorized per level, and recorded as one audited
  # +configuration_profile.applied+ activity event.
  # @spec FEATURE-APPROVAL-004
  class ApplyDefaultPosture
    NO_OP_RESULT = { applied_changes: [], skipped_levels: [] }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(account:, actor:, choice:, overrides: {})
      @account = account
      @actor = actor
      @choice = choice.to_s
      @overrides = overrides
    end

    def call
      case @choice
      when DefaultPosture::CHOICE_HUMAN_LED then apply_human_led
      when DefaultPosture::CHOICE_STANDARD, "" then NO_OP_RESULT
      else raise ArgumentError, "Unknown operating posture: #{@choice.inspect}"
      end
    end

    private

    def apply_human_led
      project = DefaultPosture.first_project(@account)
      return NO_OP_RESULT if project.blank?

      plan = DefaultPosture.plan_for(project: project, actor: @actor, overrides: @overrides)
      Configuration::Profiles::Applier.call(plan: plan, project: project, actor: @actor)
    end
  end
end
