# frozen_string_literal: true

class EgressAllowlistEntryPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  class Scope < ApplicationPolicy::Scope
  end

  private

  def account_for_record
    record.is_a?(Class) ? user&.account : record.account
  end
end
