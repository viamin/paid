# frozen_string_literal: true

module Inbox
  class InteractiveChatAccess
    def self.allowed?(user:, project:)
      new(user:, project:).allowed?
    end

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    def allowed?
      ProjectPolicy.new(user, project).manage_issues?
    end

    private

    attr_reader :project, :user
  end
end
