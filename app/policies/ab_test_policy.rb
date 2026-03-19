# frozen_string_literal: true

class AbTestPolicy < ApplicationPolicy
  def index?
    visible?
  end

  def show?
    visible?
  end

  def create?
    return false unless visible?

    has_any_account_role?(:owner, :admin)
  end

  def update?
    return false unless visible?

    has_any_account_role?(:owner, :admin)
  end

  private

  def visible?
    return false unless user.present?

    user_in_account?
  end

  def account_for_record
    record.prompt&.account
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:prompt).where(prompts: { account_id: user.account_id })
    end

    private

    attr_reader :user, :scope
  end
end
