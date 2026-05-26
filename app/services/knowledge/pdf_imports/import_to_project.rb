# frozen_string_literal: true

module Knowledge
  module PdfImports
    class ImportToProject
      ARTIFACT_TYPE = "reference_document"
      COLLECTOR_TYPE = "pdf_import"
      MAX_PDF_SIZE = 50.megabytes

      def initialize(project:, file:, actor:)
        @project = project
        @file = file
        @actor = actor
      end

      def self.call(...)
        new(...).call
      end

      def call
        validate_plan!
        validate_file!
        validate_size!

        document = Parser.call(file: file)
        chunks = Chunker.call(document: document)

        collector_run = nil

        ActiveRecord::Base.transaction do
          collector_run = project_version.collector_runs.create!(
            collector_type: COLLECTOR_TYPE,
            status: "running",
            started_at: Time.current,
            metadata: {
              source_name: document.source_name,
              title: document.title,
              imported_by_user_id: actor&.id
            }
          )

          Knowledge::ArtifactStore.call(
            project: project,
            collector_run: collector_run,
            artifact_data_list: [ artifact_data_for(document, chunks) ]
          )

          collector_run.mark_completed!(count: 1)
          project.update!(knowledge_status: "ready")
        end

        KnowledgeArtifact.bust_artifact_counts_cache(project.id)
        EmbedChunksJob.perform_later(project.id)

        {
          artifact_identifier: artifact_identifier(document),
          collector_run: collector_run,
          chunk_count: chunks.size
        }
      rescue StandardError => e
        collector_run&.mark_failed!(error: e.message) if collector_run&.persisted? && collector_run.status == "running"
        raise
      end

      private

      attr_reader :project, :file, :actor

      def validate_plan!
        return if project.account.paid_plan?

        raise ImportError, "PDF knowledge import is available on professional and enterprise plans."
      end

      def validate_file!
        raise ImportError, "Choose a PDF file to import." if file.blank?
        return if file.original_filename.to_s.downcase.end_with?(".pdf")
        return if file.content_type.to_s == "application/pdf"

        raise ImportError, "Only PDF uploads are supported."
      end

      def validate_size!
        return unless file.respond_to?(:size)
        return if file.size <= MAX_PDF_SIZE

        raise ImportError, "PDF must be smaller than 50 MB."
      end

      def project_version
        @project_version ||= project.project_versions.by_recency.first || project.project_versions.create!(
          commit_sha: "0" * 40,
          branch: project.default_branch || "main"
        )
      end

      def artifact_data_for(document, chunks)
        {
          artifact_type: ARTIFACT_TYPE,
          scope_path: "pdf_uploads/#{document.source_name}",
          identifier: artifact_identifier(document),
          content: full_document_content(document),
          metadata: {
            source_name: document.source_name,
            title: document.title,
            page_count: document.page_count,
            imported_by_user_id: actor&.id,
            imported_at: Time.current.iso8601
          },
          chunks: chunks
        }
      end

      def artifact_identifier(document)
        document.title.presence || File.basename(document.source_name, ".*")
      end

      def full_document_content(document)
        document.pages.map do |page|
          "Page #{page.fetch(:number)}\n#{page.fetch(:text)}"
        end.join("\n\n")
      end
    end
  end
end
