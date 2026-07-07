# frozen_string_literal: true

module ConfigurationProfiles
<<<<<<< HEAD
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
=======
  # Applies a serialized +Plan+ to the target account/project. Runs in a single
  # transaction, checks per-level authorization (skipping un-permitted levels
  # with a reported reason), enforces prerequisites (hard-fails the apply when
  # unmet so the user is asked to clear them first), and records a per-change
  # result for the chat reply.
  class Applier
    Target = Data.define(:project, :project_id)

    # Raised when one or more of the plan's declared prerequisites is not met.
    # Carries the unmet prerequisite hashes so callers can surface their
    # `description:` to the user.
    class UnmetPrerequisiteError < StandardError
      attr_reader :prerequisites

      def initialize(prerequisites)
        @prerequisites = prerequisites
        super(prerequisites.map { |prerequisite| prerequisite[:description] || prerequisite[:key] }.join("; "))
      end
    end

    AUTHORIZATION_GATES = {
      user: :authorize_user_level!,
      project: :authorize_project_level!,
      tenant: :authorize_tenant_level!
    }.freeze

    # Maps a prerequisite's `key:` to a check `->(account, project) { true/false }`.
    # A key with no registered check is treated as unmet (fail closed) rather
    # than silently ignored.
    PREREQUISITE_CHECKS = {
      "github_app_installed" => ->(account, _project) { account.github_installations.active.exists? }
    }.freeze

    def self.call(plan:, user:, project: nil, project_id: nil)
      target = resolve_project_target(user:, plan:, project:, project_id:)
      new(plan:, user:, target:).call
    end

    def self.resolve_project_target(user:, plan:, project:, project_id:)
      effective_project_id = project_id || project&.id || plan.project_id
      resolved_project = project || resolve_project_for(user:, project_id: effective_project_id)

      Target.new(
        project: resolved_project,
        project_id: resolved_project&.id || effective_project_id
      )
    end

    def self.resolve_project_for(user:, project_id:)
      return nil if project_id.blank?

      Project.where(account: user.account).find_by(id: project_id)
    end
    private_class_method :resolve_project_target, :resolve_project_for

    def initialize(plan:, user:, target:)
      @plan = plan
      @user = user
      @account = user.account
      @project = target.project
      @project_id = target.project_id
    end

    def call
      validate_target!
      check_prerequisites!

      results = { profile_id: @plan.profile_id, project_id: @project_id, applied: [], skipped: [] }

      # Group changes by level so all changes targeting the same record are
      # applied with a single `update!`. Per-change writes are both wasteful
      # (one SQL UPDATE per attribute) and order-dependent: a record-level
      # validation (e.g. UserSetting#validate_max_concurrent_runs_for_mode)
      # fires on every save, so applying `run_concurrency_mode: "manual"` on
      # its own can reject a plan that also sets `max_concurrent_runs` later.
      grouped_changes = @plan.changes.group_by { |change| change[:level] }

      ActiveRecord::Base.transaction do
        grouped_changes.each do |level, changes|
          gate = AUTHORIZATION_GATES[level]
          unless gate
            changes.each { |change| results[:skipped] << skipped_change(change, reason: "unknown_level") }
            next
          end

          begin
            send(gate)
          rescue Pundit::NotAuthorizedError => error
            changes.each { |change| results[:skipped] << skipped_change(change, reason: "unauthorized", detail: error.message) }
            next
          end

          target_record, permitted = target_for(level)
          update_results = apply_changes_for_record(target_record, permitted: permitted, changes: changes)
          results[:applied].concat(update_results[:applied])
          results[:skipped].concat(update_results[:skipped])
        end

        if results[:applied].any?
          Accounts::RecordActivity.call(
            account: @account,
            actor: @user,
            action: "configuration_profile.applied",
            subject: @project,
            metadata: {
              profile_id: @plan.profile_id,
              change_count: results[:applied].size,
              skipped_count: results[:skipped].size
            }
          )
        end
      end

      results
>>>>>>> origin/main
    end

    private

<<<<<<< HEAD
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
        previous_values: plan.changes.to_h { |change| [ change.field.to_s, change.from ] },
        applied_values: plan.changes.to_h { |change| [ change.field.to_s, change.to ] }
      }.merge(extra_metadata)
=======
    attr_reader :user, :account, :project, :project_id, :plan

    def validate_target!
      raise ArgumentError, "Profile not found: #{plan.profile_id}" unless ConfigurationProfiles::Registry.find(plan.profile_id)
      if plan.levels.include?(:project) && project.nil?
        raise ArgumentError, "project_id is required to apply this profile"
      end
    end

    def check_prerequisites!
      unmet = plan.prerequisites.reject { |prerequisite| prerequisite_met?(prerequisite) }
      raise UnmetPrerequisiteError, unmet if unmet.any?
    end

    def prerequisite_met?(prerequisite)
      check = PREREQUISITE_CHECKS[prerequisite[:key].to_s]
      return false unless check

      check.call(account, project)
    end

    def authorize_user_level!
      policy_allows?(record: user.settings, query: :update?, policy_class: UserSettingPolicy)
    end

    def authorize_project_level!
      raise Pundit::NotAuthorizedError, "project required" if project.nil?

      policy_allows?(record: project, query: :update?, policy_class: ProjectPolicy)
    end

    def authorize_tenant_level!
      policy_allows?(record: account, query: :update?, policy_class: AccountPolicy)
    end

    def policy_allows?(record:, query:, policy_class:)
      return if Tools::BaseTool.policy_allows?(user:, record:, query:, policy_class:)

      raise Pundit::NotAuthorizedError, "not authorized"
    end

    def target_for(level)
      case level
      when :user
        [ user.settings, user_permitted_attrs ]
      when :project
        [ project, project_permitted_attrs ]
      when :tenant
        [ account.tenant_setting!, tenant_permitted_attrs ]
      end
    end

    # Applies every change targeting a single record with one `update!`,
    # returning one audit entry per attribute. `change[:before]`/`change[:after]`
    # were captured at plan time and can go stale if the record changed in
    # between, so `before`/`after` are re-read from the live record immediately
    # before and after the write to reflect the actual transition applied here.
    def apply_changes_for_record(record, permitted:, changes:)
      applied = []
      skipped = []
      attrs_to_write = {}
      change_by_attr = {}

      changes.each do |change|
        attribute = change[:attribute].to_s.split(".").last.to_sym
        unless permitted.include?(attribute)
          skipped << skipped_change(change, reason: "unknown_attribute")
          next
        end

        attrs_to_write[attribute] = change[:after]
        change_by_attr[attribute] = change
      end

      return { applied: applied, skipped: skipped } if attrs_to_write.empty?

      before_by_attr = {}
      attrs_to_write.each_key { |attribute| before_by_attr[attribute] = record.public_send(attribute) }

      record.update!(attrs_to_write)

      attrs_to_write.each_key do |attribute|
        change = change_by_attr[attribute]
        next if change.nil?

        applied << {
          status: "applied",
          level: change[:level],
          attribute: change[:attribute],
          before: before_by_attr[attribute],
          after: record.public_send(attribute)
        }
      end

      { applied: applied, skipped: skipped }
    end

    def skipped_change(change, reason:, detail: nil)
      entry = {
        status: "skipped",
        level: change[:level],
        attribute: change[:attribute],
        reason: reason
      }
      entry[:detail] = detail if detail
      entry
    end

    def user_permitted_attrs
      Tools::UpdateUserSettings::PERMITTED_ATTRIBUTES
    end

    def project_permitted_attrs
      %i[
        max_tokens_per_run
        poll_interval_seconds
        auto_pick_skip_labels
      ]
    end

    def tenant_permitted_attrs
      Tools::UpdateTenantSettings::PERMITTED_ATTRIBUTES
>>>>>>> origin/main
    end
  end
end
