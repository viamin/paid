# frozen_string_literal: true

module OperatorConsole
  class BasePolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def index?
      operator?
    end

    def show?
      operator?
    end

    def create?
      false
    end

    def new?
      false
    end

    def update?
      operator?
    end

    def edit?
      update?
    end

    def destroy?
      false
    end

    def search?
      index?
    end

    def act_on?
      operator?
    end

    private

    def operator?
      user&.operator?
    end

    class Scope
      attr_reader :user, :scope

      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        raise Pundit::NotAuthorizedError, "must be operator" unless user&.operator?

        scope.all
      end
    end
  end
end
