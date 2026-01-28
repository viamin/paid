# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def new?
    create?
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def edit?
    update?
  end

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  private

  def user_in_account?
    user.account_id == account_for_record&.id
  end

  def account_for_record
    record.respond_to?(:account) ? record.account : record
  end

  def has_any_account_role?(*roles)
    account = account_for_record
    roles.any? { |role| user.has_role?(role, account) }
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      scope.where(account: user.account)
    end

    private

    attr_reader :user, :scope
  end
end
