# frozen_string_literal: true

class RunnerCredentialPolicy < ApplicationPolicy
  def index?
    has_any_account_role?(:owner, :admin)
  end

  def show?
    has_any_account_role?(:owner, :admin)
  end

  def new?
    has_any_account_role?(:owner, :admin)
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  def revoke?
    destroy?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user
      return scope.none unless user.has_role?(:owner, user.account) || user.has_role?(:admin, user.account)

      super
    end
  end

  private

  def account_for_record
    return user&.account if record.is_a?(Class)

    record.respond_to?(:account) ? record.account : user&.account
  end
end
