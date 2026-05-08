# frozen_string_literal: true

module Automation
  module Strategies
    # Encodes the inputs used to select a strategy version.
    #
    # Selection precedence (highest to lowest):
    #   1. Task-specific  — matches on +strategy_type+ and +task_type+
    #   2. Project-specific — matches on +strategy_type+ and +project+
    #   3. Account-specific — matches on +strategy_type+ and +account+
    #   4. Global default  — matches on +strategy_type+ only
    #
    # +metadata+ carries optional runtime signals (e.g. issue complexity,
    # language, test coverage) that registrations can use for finer-grained
    # matching in future iterations.
    class SelectionContext < Data.define(:strategy_type, :project, :account, :account_id, :task_type, :metadata)
      EMPTY_METADATA = {}.freeze

      def self.build(strategy_type:, project: nil, account: nil, task_type: nil, metadata: nil)
        account_id = account&.id || account_id_from(project)
        account ||= loaded_project_account(project)

        new(
          strategy_type: strategy_type.to_s,
          project: project,
          account: account,
          account_id: account_id,
          task_type: task_type&.to_s,
          metadata: (metadata || EMPTY_METADATA).freeze
        )
      end

      def self.account_id_from(project)
        return unless project&.respond_to?(:account_id)

        project.account_id
      end

      def self.loaded_project_account(project)
        return unless project&.respond_to?(:association)

        association = project.association(:account)
        return unless association.loaded?

        project.account
      end
    end
  end
end
