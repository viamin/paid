# frozen_string_literal: true

module ConfigurationProfiles
  # Applies a serialized +Plan+ to the target account/project. Runs in a single
  # transaction, checks per-level authorization (skipping un-permitted levels
  # with a reported reason), enforces prerequisites (hard-fails the apply when
  # unmet so the user is asked to clear them first), and records a per-change
  # result for the chat reply.
  class Applier
    AUTHORIZATION_GATES = {
      user: :authorize_user_level!,
      project: :authorize_project_level!,
      tenant: :authorize_tenant_level!
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
            public_send(gate)
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
        apply_user_change(change)
      when :project
        apply_project_change(change)
      when :tenant
        apply_tenant_change(change)
      else
        skipped_change(change, reason: "unknown_level")
      end
    end

    def apply_user_change(change)
      attrs = change[:after]
      return skipped_change(change, reason: "no_attrs") unless attrs.is_a?(Hash)

      user.settings.update!(attrs.symbolize_keys.slice(*user_permitted_attrs))
      {
        status: "applied",
        level: :user,
        attribute: change[:attribute],
        before: change[:before],
        after: change[:after]
      }
    end

    def apply_project_change(change)
      attrs = change[:after]
      return skipped_change(change, reason: "no_attrs") unless attrs.is_a?(Hash)

      project.update!(attrs.symbolize_keys.slice(*project_permitted_attrs))
      {
        status: "applied",
        level: :project,
        attribute: change[:attribute],
        before: change[:before],
        after: change[:after]
      }
    end

    def apply_tenant_change(change)
      attrs = change[:after]
      return skipped_change(change, reason: "no_attrs") unless attrs.is_a?(Hash)

      tenant_setting = account.tenant_setting!
      tenant_setting.update!(attrs.symbolize_keys.slice(*tenant_permitted_attrs))
      {
        status: "applied",
        level: :tenant,
        attribute: change[:attribute],
        before: change[:before],
        after: change[:after]
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
