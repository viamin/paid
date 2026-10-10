# frozen_string_literal: true

# Personal access tokens are per-user credentials: any signed-in user may
# manage their own tokens, and no user may touch another user's — even
# within the same account.
class PersonalAccessTokenPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    own_token?
  end

  def create?
    user.present?
  end

  def new?
    create?
  end

  def update?
    own_token?
  end

  def destroy?
    own_token?
  end

  private

  def own_token?
    user.present? && record.is_a?(PersonalAccessToken) && record.user_id == user.id
  end

  class Scope < Scope
    def resolve
      scope.where(user: user)
    end
  end
end
