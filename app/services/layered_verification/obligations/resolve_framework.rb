# frozen_string_literal: true

require "digest"

module LayeredVerification
  module Obligations
    class ResolveFramework
      # @spec LAYERED-VERIFY-001
      # @spec LAYERED-VERIFY-002
      # @spec LAYERED-VERIFY-003
      Result = Data.define(:framework, :external_identity, :external_revision, :canonical_source_path, :offers)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, repo_path:, okf_paths: [])
        @project = project
        @repo_path = repo_path
        @okf_paths = okf_paths
      end

      def call
        if lid_project?
          return Result.new(
            framework: "lid", external_identity: nil, external_revision: nil,
            canonical_source_path: nil, offers: []
          )
        end

        okf_reference || offered_cir
      end

      private

      attr_reader :project, :repo_path, :okf_paths

      def lid_project?
        project.lid_mode.to_s.in?(%w[full scoped])
      end

      def okf_reference
        path = okf_concept_paths.first
        return unless path

        relative_path = path.delete_prefix("#{repository_root}/")
        Result.new(
          framework: "okf",
          external_identity: relative_path,
          external_revision: Digest::SHA256.file(path).hexdigest,
          canonical_source_path: relative_path,
          offers: []
        )
      end

      def offered_cir
        Result.new(
          framework: "paid_offered_cir",
          external_identity: nil,
          external_revision: nil,
          canonical_source_path: nil,
          offers: %w[okf_compatible_cir lid]
        )
      end

      def okf_concept_paths
        roots.flat_map { |root| Dir.glob(File.join(root, "**", "*.md")).sort }
          .filter_map { |path| contained_okf_document_path(path) }
      end

      def roots
        ([ ".okf" ] + Array(okf_paths)).filter_map do |relative_path|
          path = File.expand_path(relative_path, repository_root)
          next unless path.start_with?("#{repository_root}/")

          resolved = File.realpath(path)
          resolved if resolved.start_with?("#{repository_root}/") && File.directory?(resolved)
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end.uniq
      end

      def repository_root
        @repository_root ||= File.realpath(repo_path)
      rescue Errno::ENOENT, Errno::EACCES
        File.expand_path(repo_path)
      end

      def contained_okf_document_path(path)
        resolved_path = File.realpath(path)
        return unless resolved_path.start_with?("#{repository_root}/")
        return unless File.file?(resolved_path)

        resolved_path if Knowledge::Okf::Frontmatter.parse(File.read(resolved_path)).valid?
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end
  end
end
