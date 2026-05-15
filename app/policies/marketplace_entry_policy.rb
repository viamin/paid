# frozen_string_literal: true

class MarketplaceEntryPolicy < ApplicationPolicy
  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    has_any_account_role?(:owner, :admin, :member)
  end

  def manage_rules?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  class Scope < Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account: user.account)
    end
  end
end
