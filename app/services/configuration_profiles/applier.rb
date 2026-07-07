# frozen_string_literal: true

module ConfigurationProfiles
  # Applies a serialized +Plan+ to the target account/project. Runs in a single
  # transaction, checks per-level authorization (skipping un-permitted levels
  # with a reported reason), enforces prerequisites (hard-fails the apply when
  # unmet so the user is asked to clear them first), and records a per-change
  # result for the chat reply.
  class Applier
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

    def self.call(...)
      new(...).call
    end

    def initialize(plan:, user:, project: nil, project_id: nil)
      @plan = plan
      @user = user
      @account = user.account
      @project = project || resolve_project(project_id)
      @project_id = @project&.id || project_id
    end

    def call
      validate_target!
      check_prerequisites!

      results = { profile_id: @plan.profile_id, project_id: @project_id, applied: [], skipped: [] }

      ActiveRecord::Base.transaction do
        @plan.changes.each do |change|
          level = change[:level]
          gate = AUTHORIZATION_GATES[level]
          unless gate
            results[:skipped] << skipped_change(change, reason: "unknown_level")
            next
          end

          begin
            send(gate)
          rescue Pundit::NotAuthorizedError => error
            results[:skipped] << skipped_change(change, reason: "unauthorized", detail: error.message)
            next
          end

          result = apply_change(change)
          if result[:status] == "applied"
            results[:applied] << result
          else
            results[:skipped] << result
          end
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
    end

    private

    attr_reader :user, :account, :project, :project_id, :plan

    def resolve_project(project_id)
      return nil if project_id.blank?

      Project.where(account: account).find_by(id: project_id)
    end

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
      result = policy_class.new(user, record).public_send(query)
      raise Pundit::NotAuthorizedError, "not authorized" unless result
    end

    def apply_change(change)
      case change[:level]
      when :user
        apply_attribute_change(record: user.settings, permitted: user_permitted_attrs, change: change)
      when :project
        apply_attribute_change(record: project, permitted: project_permitted_attrs, change: change)
      when :tenant
        apply_attribute_change(record: account.tenant_setting!, permitted: tenant_permitted_attrs, change: change)
      else
        # Unreachable in practice: `call` already skips levels missing from
        # AUTHORIZATION_GATES before ever invoking `apply_change`. Raise
        # instead of silently skipping so a future drift between the two
        # dispatch tables fails loudly rather than looking like a no-op apply.
        raise ArgumentError, "unexpected change level: #{change[:level].inspect}"
      end
    end

    # `change[:before]`/`change[:after]` were captured by `Profile.build_plan`
    # at plan time, so they can go stale if the record changed between plan
    # and apply. Re-read `before` from the live record immediately before the
    # write and `after` from the record immediately after, so the returned
    # audit result always reflects the actual transition applied here.
    def apply_attribute_change(record:, permitted:, change:)
      attribute = change[:attribute].to_s.split(".").last.to_sym
      return skipped_change(change, reason: "unknown_attribute") unless permitted.include?(attribute)

      before = record.public_send(attribute)
      record.update!(attribute => change[:after])
      {
        status: "applied",
        level: change[:level],
        attribute: change[:attribute],
        before: before,
        after: record.public_send(attribute)
      }
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
    end
  end
end
