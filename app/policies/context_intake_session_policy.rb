# frozen_string_literal: true

class ContextIntakeSessionPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    has_any_account_role?(:owner, :admin, :member)
  end

  def complete?
    has_any_account_role?(:owner, :admin, :member)
  end

  private

  def account_for_record
    if record.is_a?(ContextIntakeSession)
      record.project.account
    else
      record.respond_to?(:account) ? record.account : record
    end
  end
end
