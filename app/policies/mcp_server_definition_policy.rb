# frozen_string_literal: true

class McpServerDefinitionPolicy < ApplicationPolicy
  def index?
    has_any_account_role?(:owner, :admin)
  end

  def show?
    has_any_account_role?(:owner, :admin)
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      if user.has_role?(:owner, user.account) || user.has_role?(:admin, user.account)
        scope.where(account: user.account)
      else
        scope.none
      end
    end
  end
end
