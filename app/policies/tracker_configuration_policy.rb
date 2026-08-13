# frozen_string_literal: true

class TrackerConfigurationPolicy < ApplicationPolicy
  # show?, create?, update? inherited from ApplicationPolicy

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  private

  def account_for_record
    record.account
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(configurable_type: "Account", configurable_id: user.account_id)
        .or(scope.where(configurable_type: "User", configurable_id: user.id))
        .or(scope.where(
          configurable_type: "Project",
          configurable_id: user.account.projects.select(:id)
        ))
    end
  end
end
