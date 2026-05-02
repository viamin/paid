# frozen_string_literal: true

module Tools
  class BaseTool
    include Pundit::Authorization

    attr_reader :user, :session

    def initialize(user:, session:)
      @user = user
      @session = session
    end

    def call(**_args)
      raise NotImplementedError, "#{self.class}#call must be implemented"
    end

    def self.tool_name
      raise NotImplementedError, "#{name}.tool_name must be implemented"
    end

    def self.description
      raise NotImplementedError, "#{name}.description must be implemented"
    end

    def self.input_schema
      { type: "object", properties: {} }
    end

    def self.definition
      {
        name: tool_name,
        description: description,
        inputSchema: input_schema
      }
    end

    def self.write_operation?
      false
    end

    private

    # Pundit expects current_user
    def current_user
      user
    end

    def account
      user.account
    end

    def scoped_projects
      Project.where(account:)
    end
  end
end
