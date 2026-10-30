# frozen_string_literal: true

module TechnicalPrerequisites
  # Turns reviewed criterion-to-recipe selections into honest Inbox actions.
  # A stale assessment or an unrelated project check never becomes a run button.
  class InboxActions
    Action = Data.define(:criterion, :requirement, :setup_action) do
      def ready? = requirement.present? && setup_action.nil?
    end

    def self.call(...) = new(...).call

    def initialize(project:, actor:, assessment:, source_run:)
      @project = project
      @actor = actor
      @assessment = assessment
      @source_run = source_run
    end

    # @spec PARTIAL-CLOSEOUT-032
    def call
      return [] if assessment.stale?

      assessment.criteria.filter_map do |criterion|
        next unless criterion["state"].in?(%w[unmet unknown])
        next unless criterion["validation_kind"].in?(%w[native tool_sidecar])

        requirement = requirements[criterion["validation_requirement_id"].to_i]
        Action.new(criterion: criterion, requirement: requirement,
          setup_action: setup_action(criterion, requirement))
      end
    end

    private

    attr_reader :project, :actor, :assessment, :source_run

    def requirements
      @requirements ||= PreCommitRequirement.resolve(project:, user: actor).index_by(&:id)
    end

    def setup_action(criterion, requirement)
      return "Prepare a reviewed validation recipe for this criterion, then run a fresh acceptance audit." unless requirement
      return "Select an implementation run with a pinned checkout before validating this criterion." unless source_run&.base_commit_sha.present?
      return unless criterion["validation_kind"] == "tool_sidecar"
      attached = source_run.tool_sidecar_snapshot.any? do |tool|
        tool["name"] == criterion["validation_tool_name"] && criterion["validation_tool_name"].present?
      end
      unless attached
        action = "Attach the criterion's allowlisted tool sidecar to a pinned run, then run a fresh acceptance audit."
        return action if FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)

        return "#{action} Request scoped pilot authorization to enable marketplace_tool_sidecars for this project."
      end
      return if FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)

      "Request scoped pilot authorization to enable marketplace_tool_sidecars for this project."
    end
  end
end
