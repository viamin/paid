# frozen_string_literal: true

class ServiceContainerPolicy < ApplicationPolicy
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

  private

  def account_for_record
    user&.account
  end
end
