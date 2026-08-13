# frozen_string_literal: true

module Automation
  class Result < Data.define(:decisions)
    class << self
      def noop
        new(decisions: [ Decision.noop ])
      end
    end

    def to_h
      { decisions: decisions.map(&:to_h) }
    end
  end
end
