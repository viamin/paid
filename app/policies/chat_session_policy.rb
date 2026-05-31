# frozen_string_literal: true

class ChatSessionPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    has_any_account_role?(:owner, :admin, :member)
  end

  def destroy?
    has_any_account_role?(:owner, :admin, :member)
  end

  def archive?
    has_any_account_role?(:owner, :admin, :member)
  end
end
