# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Resolves the bounded scope of an audit before dispatch: the business
    # slice, the source references it reads, the repository revision every
    # check is bound to, the budget the run may spend, and the obligations it
    # covers. Resolution is structural — no semantic judgment happens here.
    #
    # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
    class ResolveScope
      Scope = Data.define(:scope_description, :sources, :target_revision, :budget, :obligations, :notes) do
        def source_paths = sources.map { |source| source["path"] }
      end

      DEFAULT_BUDGET = {
        "max_checks" => 8,
        "max_tokens" => 120_000,
        "max_duration_seconds" => 1800
      }.freeze
      MAX_CHECKS = 25
      MAX_SOURCES = 25
      MAX_SCOPE_LENGTH = 4_000

      def self.call(...)
        new(...).call
      end

      def initialize(project:, scope_description:, sources: [], target_revision: nil, budget: {}, obligations: nil,
        revision_resolver: nil)
        @project = project
        @scope_description = scope_description.to_s.strip
        @sources = sources
        @target_revision = target_revision.to_s.strip
        @budget = budget || {}
        @obligations = obligations
        @revision_resolver = revision_resolver
      end

      def call
        raise ArgumentError, "scope_description is required" if scope_description.blank?

        Scope.new(
          scope_description: scope_description.truncate(MAX_SCOPE_LENGTH),
          sources: resolved_sources,
          target_revision: resolved_revision,
          budget: resolved_budget,
          obligations: resolved_obligations,
          notes: notes
        )
      end

      private

      attr_reader :budget, :obligations, :project, :revision_resolver, :scope_description, :sources, :target_revision

      def resolved_sources
        paths = sources.filter_map { |source| source_path(source) }
        raise ArgumentError, "at least one source reference is required" if paths.empty?
        raise ArgumentError, "an audit may read at most #{MAX_SOURCES} sources" if paths.size > MAX_SOURCES

        paths.uniq.sort.map { |path| { "path" => path } }
      end

      def source_path(source)
        path = source.is_a?(Hash) ? (source["path"] || source[:path]) : source
        path = path.to_s.strip
        raise ArgumentError, "a source reference must be a repository-relative path" unless valid_source_path?(path)

        path
      end

      def valid_source_path?(path)
        return false if path.blank?
        return false if path.include?("\0")
        return false if path.start_with?("/")
        return false if path.split("/").include?("..")

        true
      end

      def resolved_revision
        return target_revision if target_revision.present?

        resolver = revision_resolver || LayeredVerification::Projects::CurrentRevision
        resolver.call(project:)
      end

      def resolved_budget
        requested = budget.respond_to?(:deep_stringify_keys) ? budget.deep_stringify_keys : {}
        merged = DEFAULT_BUDGET.merge(requested)

        {
          "max_checks" => merged["max_checks"].to_i.clamp(1, MAX_CHECKS),
          "max_tokens" => merged["max_tokens"].to_i.clamp(1, 2_000_000),
          "max_duration_seconds" => merged["max_duration_seconds"].to_i.clamp(30, 86_400)
        }
      end

      def resolved_obligations
        return obligations if obligations

        project.layered_verification_obligations.order(:id).to_a
      end

      def notes
        return [] if resolved_revision.present?

        [ "The repository revision could not be resolved; the audit records that its checks ran against an unpinned revision." ]
      end
    end
  end
end
