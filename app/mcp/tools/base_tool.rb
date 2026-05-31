# frozen_string_literal: true

module Tools
  class UnauthorizedError < Pundit::NotAuthorizedError; end

  class BaseTool
    include Pundit::Authorization

    attr_reader :user, :session

    def initialize(user:, session:)
      @user = user
      @session = session
    end

    def call(**args)
      dispatch(**args)
    end

    def dispatch(**args)
      raise UnauthorizedError, "Tool calls require an authenticated user" if user.blank?

      TenantContext.with(account) do
        reset_authorization_tracking!
        run_declared_authorizations!(args)
        raise UnauthorizedError, "#{self.class.tool_name} must authorize before execution" unless preflight_authorized?

        perform(**args)
      end
    end

    def perform(**_args)
      raise NotImplementedError, "#{self.class}#perform must be implemented"
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

    def self.available_to?(user:)
      user.present?
    end

    def self.run_agent_available_to?(user:)
      return false if user.blank?

      record = Project.new(account: user.account)
      return true if policy_allows?(user:, record:, query: :run_agent?, policy_class: ProjectPolicy)

      Pundit.policy_scope!(user, Project).any? do |project|
        policy_allows?(user:, record: project, query: :run_agent?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.policy_allows?(user:, record:, query:, policy_class: nil)
      return false if user.blank?

      policy = policy_class ? policy_class.new(user, record) : Pundit.policy(user, record)
      policy&.public_send(query) == true
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.authorize(query, resolver = nil, policy_class: nil, &block)
      resolver ||= block
      raise ArgumentError, "#{name}.authorize requires a resolver" unless resolver

      own_authorization_rules << {
        query: query,
        resolver: resolver,
        policy_class: policy_class
      }
    end

    def self.authorization_rules
      inherited_rules = superclass.respond_to?(:authorization_rules) ? superclass.authorization_rules : []
      inherited_rules + own_authorization_rules
    end

    private

    def authorize(record, query = nil, policy_class: nil)
      super
    end
    alias_method :authorize!, :authorize

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

    def reset_authorization_tracking!
      @preflight_authorization_performed = false
    end

    def preflight_authorized?
      @preflight_authorization_performed
    end

    def self.own_authorization_rules
      @own_authorization_rules ||= []
    end

    def run_declared_authorizations!(args)
      self.class.authorization_rules.each do |rule|
        record = instance_exec(args, &rule[:resolver])
        @preflight_authorization_performed = true
        authorize(record, rule[:query], policy_class: rule[:policy_class])
      end
    end
  end
end
