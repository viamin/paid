# frozen_string_literal: true

module Automation
  # Shared input for automation strategies.
  #
  # A Context carries the project being automated, the subject record
  # (issue or pull request), and a free-form metadata hash where upstream
  # layers can attach signals or scan data collected from providers.
  #
  # Strategies (auto-pick, auto-continue, auto-review, auto-merge) all
  # share this input shape so that future coordinators can evaluate them
  # uniformly without knowing their internals.
  class Context < Data.define(:project, :record, :metadata)
    EMPTY_METADATA = {}.freeze

    def self.build(record:, project: nil, metadata: nil)
      project ||= record.respond_to?(:project) ? record.project : nil
      raise ArgumentError, "Automation::Context requires a project" if project.nil?

      new(
        project: project,
        record: record,
        metadata: (metadata || EMPTY_METADATA).freeze
      )
    end

    def metadata_fetch(key, default = nil)
      metadata.fetch(key, default)
    end

    def with_metadata(extra)
      self.class.build(
        project: project,
        record: record,
        metadata: metadata.merge(extra || {})
      )
    end
  end
end
