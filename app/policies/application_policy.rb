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
    has_account_role?(:owner)
  end

  private

  def user_in_account?
    return false unless user&.account_id

    user.account_id == account_for_record&.id
  end

  def account_for_record
    record.respond_to?(:account) ? record.account : record
  end

  def has_account_role?(role)
    return false unless user

    user.has_role?(role, account_for_record)
  end

  def has_any_account_role?(*roles)
    return false unless user

    account = account_for_record
    roles.any? { |role| user.has_role?(role, account) }
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      if scope.column_names.include?("account_id")
        scope.where(account: user.account)
      else
        raise NotImplementedError, "#{self.class} must implement #resolve for models without account association"
      end
    end

    private

    attr_reader :user, :scope
  end
end
