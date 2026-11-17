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
      changes = project.transaction do
        records_by_change = plan.changes.to_h do |change|
          [ change, field_set.write(project, change.field, change.to, actor: actor) ]
        end
        records_by_change.values.uniq.each { |record| record.save! if record.changed? && !record.equal?(project) }
        project.save!
        persisted = persisted_changes(records_by_change)
        activity = record_activity(persisted) if persisted.any?
        persisted
      end
      Result.new(project:, changes:, activity:)
    end

    private

    attr_reader :project, :plan, :actor, :action, :extra_metadata, :field_set

    def persisted_changes(records_by_change)
      records_by_change.filter_map do |change, record|
        change unless record.respond_to?(:applied?) && !record.applied?
      end
    end

    def record_activity(changes)
      Accounts::RecordActivity.call(
        account: project.account,
        actor:,
        action:,
        subject: project,
        metadata: activity_metadata(changes)
      )
    end

    def activity_metadata(changes)
      {
        label: plan.label,
        source: plan.source.to_s,
        profile_key: plan.reference&.to_s,
        project_name: project.name,
        changed_fields: changes.map { |change| change.field.to_s },
        previous_values: changes.to_h { |change| [ change.field.to_s, change.from ] },
        applied_values: changes.to_h { |change| [ change.field.to_s, change.to ] }
      }.merge(extra_metadata)
    end
  end
end
