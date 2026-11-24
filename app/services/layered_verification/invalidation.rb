# frozen_string_literal: true

module LayeredVerification
  # Classifies append-only evidence for a later audit without changing the
  # outcome it originally recorded. A digest is an identity aid, not evidence
  # that all semantic dependencies were declared.
  # @spec LAYERED-VERIFY-019
  class Invalidation
    Impact = Data.define(:reusable_result_ids, :invalidated_result_ids, :limitations)

    def self.call(...) = new(...).call

    def initialize(obligations:, target_revision:, dependencies: {}, github_client: nil)
      @obligations = obligations
      @target_revision = target_revision.to_s
      @dependencies = dependencies.to_h.deep_stringify_keys
      @github_client = github_client
      @changed_paths = {}
    end

    def call
      reusable, invalidated = results.partition { |result| reusable?(result) }
      Impact.new(reusable.map(&:id), invalidated.map(&:id), limitations(invalidated))
    end

    def reusable?(result)
      revision = result.input_revision.to_h.deep_stringify_keys
      complete_dependency_basis?(revision) && code_unaffected?(result, revision) &&
        revision["external_revision"] == result.obligation.external_revision &&
        revision.fetch("dependencies") == dependencies
    end

    private

    attr_reader :dependencies, :github_client, :obligations, :target_revision

    def results
      LayeredVerificationCheckResult.where(obligation: obligations)
        .includes(obligation: :correspondence_claims).order(:id).to_a
    end

    def code_unaffected?(result, revision)
      scope = ScopeSnapshot.call(result.obligation)
      recorded_scope = Array(revision["scope_paths"]).map(&:to_s).uniq.sort
      return false unless scope.complete && recorded_scope == scope.paths
      return true if revision["code"] == target_revision

      changed = changed_paths(result.obligation.project, revision["code"])
      changed && (changed & recorded_scope).empty?
    end

    def changed_paths(project, prior_revision)
      key = [ project.id, prior_revision ]
      @changed_paths.fetch(key) do
        @changed_paths[key] = compare_paths(project, prior_revision)
      end
    end

    def compare_paths(project, prior_revision)
      files = (github_client || project.client).compare(project.full_name, prior_revision, target_revision).files
      return if files.nil? || files.size >= 300

      files.flat_map do |file|
        [ file.filename, (file.previous_filename if file.respond_to?(:previous_filename)) ]
      end.map(&:to_s).reject(&:blank?).uniq
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def complete_dependency_basis?(revision)
      revision["code"].present? && revision["external_revision"].present? &&
        concrete_dependencies?(revision["dependencies"])
    end

    def concrete_dependencies?(basis)
      return false unless basis.is_a?(Hash)

      environment = basis["environment"]
      versions = basis["producer_versions"]
      tools = basis["tool_versions"]
      environment.is_a?(Hash) && environment["immutable"] == true && environment["digest"].present? &&
        versions.is_a?(Hash) && concrete_version?(versions["paid"]) &&
        tools.is_a?(Hash) && tools["tlc_runtime_image_digest"] == environment["digest"]
    end

    def concrete_version?(version)
      version.present? && version != "unversioned"
    end

    def limitations(invalidated)
      return [] if invalidated.empty?

      [ "Evidence without a complete dependency and scope-impact basis was invalidated conservatively; content hashes alone do not establish dependency completeness." ]
    end
  end
end
