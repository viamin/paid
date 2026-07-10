# frozen_string_literal: true

class PreviewSessionPolicy < ApplicationPolicy
  # Previewing changes is a read operation. Any user with an account-level or
  # project-level membership on the session's project may open the preview UI
  # and receive a token. The proxied content itself is gated by the token.
  def show?
    return false unless user_in_account?

    ProjectPolicy.new(user, record.project).run_agent?
  end

  def stop?
    ProjectPolicy.new(user, record.project).update?
  end

  private

  def account_for_record
    record.project.account
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:project).where(projects: { account_id: user.account_id })
    end
  end
end
