# frozen_string_literal: true

module Knowledge
  class BaseCollector
    attr_reader :project, :project_version, :collector_run, :options

    def initialize(project:, project_version:, collector_run:, options: {})
      @project = project
      @project_version = project_version
      @collector_run = collector_run
      @options = options
    end

    # Must return Array<Hash> with keys:
    #   artifact_type:, scope_path:, identifier:, content:, metadata:, chunks: [...]
    # Each chunk: { chunk_type:, content:, scope_tags:, sequence: }
    def collect
      raise NotImplementedError, "#{self.class}#collect must be implemented"
    end

    def collector_type
      raise NotImplementedError, "#{self.class}#collector_type must be implemented"
    end

    def tool_version
      nil
    end
  end
end
