# frozen_string_literal: true

module Knowledge
  class SkipCollector < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end
end
