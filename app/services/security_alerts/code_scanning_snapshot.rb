# frozen_string_literal: true

module SecurityAlerts
  # An explicitly scoped result set that is safe to use for lifecycle changes.
  # @spec GITHUB-SYNC-019
  CodeScanningSnapshot = Data.define(:repository, :branch, :configuration_scope, :complete, :alerts) do
    def authoritative_for?(project)
      complete && repository == project.full_name && branch == project.default_branch && configuration_scope == :all
    end
  end
end
