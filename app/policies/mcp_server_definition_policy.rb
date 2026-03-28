# frozen_string_literal: true

class McpServerDefinitionPolicy < ApplicationPolicy
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
end
