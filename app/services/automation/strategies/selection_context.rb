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
    class SelectionContext < Data.define(:strategy_type, :project, :account, :task_type, :metadata)
      EMPTY_METADATA = {}.freeze

      def self.build(strategy_type:, project: nil, account: nil, task_type: nil, metadata: nil)
        account ||= project&.respond_to?(:account) ? project.account : nil

        new(
          strategy_type: strategy_type.to_s,
          project: project,
          account: account,
          task_type: task_type&.to_s,
          metadata: (metadata || EMPTY_METADATA).freeze
        )
      end
    end
  end
end
