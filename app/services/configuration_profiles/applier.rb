# frozen_string_literal: true

module ConfigurationProfiles
  # Applies a {Plan} to a {::Project}: writes each change's target value via
  # {FieldSet}, persists, and records an {AccountActivityEvent} through
  # {Accounts::RecordActivity} carrying the previous values so the change can
  # be reversed by {Rollback}.
  #
  # The applier is generic over the field set (defaults to {FieldSet}) so the
  # same code can drive configuration profiles and future batch operations.
  class Applier
    APPLIED_ACTION = "configuration_profile.applied"

    Result = Data.define(:project, :changes, :activity)

    def self.call(project, plan, actor: nil, action: APPLIED_ACTION, extra_metadata: {}, field_set: FieldSet)
      new(project:, plan:, actor:, action:, extra_metadata:, field_set:).call
    end

    def initialize(project:, plan:, actor:, action:, extra_metadata:, field_set:)
      @project = project
      @plan = plan
      @actor = actor
      @action = action
      @extra_metadata = extra_metadata
      @field_set = field_set
    end

    def call
      return Result.new(project:, changes: [], activity: nil) if plan.empty?

      activity = nil
      project.transaction do
        plan.changes.each { |change| field_set.write(project, change.field, change.to) }
        project.save!
        activity = record_activity
      end
      Result.new(project:, changes: plan.changes, activity:)
    end

    private

    attr_reader :project, :plan, :actor, :action, :extra_metadata, :field_set

    def record_activity
      Accounts::RecordActivity.call(
        account: project.account,
        actor:,
        action:,
        subject: project,
        metadata: activity_metadata
      )
    end

    def activity_metadata
      {
        label: plan.label,
        source: plan.source.to_s,
        profile_key: plan.reference&.to_s,
        project_name: project.name,
        changed_fields: plan.applied_fields.map(&:to_s),
        previous_values: plan.changes.to_h { |change| [change.field.to_s, change.from] },
        applied_values: plan.changes.to_h { |change| [change.field.to_s, change.to] }
      }.merge(extra_metadata)
    end
  end
end
