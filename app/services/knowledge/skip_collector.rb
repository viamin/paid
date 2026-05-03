# frozen_string_literal: true

module Knowledge
  class SkipCollector < StandardError
    attr_reader :reason

    def initialize(reason, preserve_existing_artifacts: false)
      @reason = reason
      @preserve_existing_artifacts = preserve_existing_artifacts
      super(reason)
    end

    def preserve_existing_artifacts?
      @preserve_existing_artifacts
    end
  end
end
