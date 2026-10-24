# frozen_string_literal: true

require "digest"

module LayeredVerification
  module Obligations
    class ResolveFramework
      # @spec LAYERED-VERIFY-001
      # @spec LAYERED-VERIFY-002
      # @spec LAYERED-VERIFY-003
      Result = Data.define(:framework, :external_identity, :external_revision, :offers)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, repo_path:, okf_paths: [])
        @project = project
        @repo_path = repo_path
        @okf_paths = okf_paths
      end

      def call
        return Result.new(framework: "lid", external_identity: nil, external_revision: nil, offers: []) if lid_project?

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
          offers: []
        )
      end

      def offered_cir
        Result.new(
          framework: "paid_offered_cir",
          external_identity: nil,
          external_revision: nil,
          offers: %w[okf_compatible_cir lid]
        )
      end

      def okf_concept_paths
        roots.flat_map { |root| Dir.glob(File.join(root, "**", "*.md")).sort }.select { |path| okf_document?(path) }
      end

      def roots
        ([ ".okf" ] + Array(okf_paths)).filter_map do |relative_path|
          path = File.expand_path(relative_path, repository_root)
          path if path.start_with?("#{repository_root}/") && File.directory?(path)
        end.uniq
      end

      def repository_root
        @repository_root ||= File.realpath(repo_path)
      rescue Errno::ENOENT, Errno::EACCES
        File.expand_path(repo_path)
      end

      def okf_document?(path)
        Knowledge::Okf::Frontmatter.parse(File.read(path)).valid?
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end
  end
end
