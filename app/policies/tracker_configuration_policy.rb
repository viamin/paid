# frozen_string_literal: true

class TrackerConfigurationPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

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
          configurable_id: user.account.project_ids
        ))
    end
  end
end
