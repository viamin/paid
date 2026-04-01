# frozen_string_literal: true

class PreCommitRequirementPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def create?
    owns_user_level_record? || has_any_account_role?(:owner, :admin)
  end

  def update?
    owns_user_level_record? || has_any_account_role?(:owner, :admin)
  end

  def destroy?
    owns_user_level_record? || has_any_account_role?(:owner, :admin)
  end

  private

  def owns_user_level_record?
    record.user_level? && record.user_id == user.id
  end

  def account_for_record
    record.account
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account: user.account)
    end

    private

    attr_reader :user, :scope
  end
end
