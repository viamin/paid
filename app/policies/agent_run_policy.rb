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
    project = record.is_a?(AgentRun) ? record.project : record
    return false unless project.is_a?(Project)

    ProjectPolicy.new(user, project).run_agent?
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
