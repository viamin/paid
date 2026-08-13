# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Outcome of a {Automation::Providers::RepositoryProvider#merge_pull_request}
      # call.
      #
      # - +merged+ [Boolean] +true+ when the PR is merged (including
      #   already-merged outcomes).
      # - +sha+ [String, nil] Resulting merge commit SHA. Nil when the
      #   provider did not return one (e.g. squash merge into a
      #   fast-forward branch where the provider reports success without a
      #   distinct merge commit).
      # - +message+ [String, nil] Human-readable summary the provider
      #   returned. May be the merge commit message or a status line.
      MergeResult = ::Data.define(:merged, :sha, :message)
    end
  end
end
