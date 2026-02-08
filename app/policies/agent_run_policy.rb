# frozen_string_literal: true

class AgentRunPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def new?
    run_agent?
  end

  def create?
    run_agent?
  end

  private

  def run_agent?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || has_project_role?
  end

  def has_project_role?
    project = record.is_a?(AgentRun) ? record.project : record
    return false unless user && project.is_a?(Project)

    user.has_any_role?(:project_admin, :project_member, project)
  end

  def account_for_record
    if record.is_a?(AgentRun)
      record.project.account
    else
      record.respond_to?(:account) ? record.account : record
    end
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:project).where(projects: { account_id: user.account_id })
    end
  end
end
