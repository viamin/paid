# frozen_string_literal: true

# Inbox entries are not a single AR model — Inbox::Queue/Count/FindEntry
# already scope every lookup to `user: current_user`, so the only
# authorization question here is "is there a signed-in user at all."
class InboxPolicy < ApplicationPolicy
  def index? = user.present?
  def count? = user.present?
  def show? = user.present?
  def chat? = user.present?

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope
    end
  end
end
