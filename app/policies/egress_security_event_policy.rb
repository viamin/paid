# frozen_string_literal: true

class EgressSecurityEventPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account_id: user.account_id)
    end

    private

    attr_reader :user, :scope
  end

  private

  def account_for_record
    record.is_a?(Class) ? user&.account : record.account
  end
end
