# frozen_string_literal: true

module MarketplaceEntries
  class ImportFromPdf
    class ImportError < StandardError; end

    def initialize(account:, actor:, params:)
      @account = account
      @actor = actor
      @params = params
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate_plan!
      validate_file!

      document = Knowledge::PdfImports::Parser.call(file: params[:pdf_file])
      chunks = Knowledge::PdfImports::Chunker.call(document: document)

      entry = account.marketplace_entries.build(
        name: params[:name].presence || document.title,
        entry_type: params[:entry_type].presence || "skill",
        description: params[:description].presence || "Imported from #{document.source_name}",
        provider_format: "canonical_v1",
        usage_guidance: usage_guidance(document),
        team_scope: "account",
        status: params[:status].presence || "draft",
        added_by_name: actor&.name.presence || actor&.email.to_s,
        added_by_email: actor&.email.to_s
      )
      entry.tags_csv = params[:tags_csv].to_s

      ActiveRecord::Base.transaction do
        entry.save!
        entry.create_version!(
          changelog: "Imported from PDF #{document.source_name}",
          canonical_artifact: canonical_artifact_for(document, chunks),
          renderers: {},
          compatibility_constraints: {},
          review_metadata: review_metadata_for(document, chunks)
        )
      end

      entry
    rescue ActiveRecord::RecordInvalid => e
      raise ImportError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :account, :actor, :params

    def validate_plan!
      return if account.paid_plan?

      raise ImportError, "Marketplace PDF import is available on professional and enterprise plans."
    end

    def validate_file!
      file = params[:pdf_file]
      raise ImportError, "Choose a PDF file to import." if file.blank?
      return if file.original_filename.to_s.downcase.end_with?(".pdf")
      return if file.content_type.to_s == "application/pdf"

      raise ImportError, "Only PDF uploads are supported."
    end

    def usage_guidance(document)
      params[:usage_guidance].presence ||
        "Imported from #{document.source_name}. Attach this entry when the run needs guidance from #{document.title}."
    end

    def canonical_artifact_for(document, chunks)
      {
        "attachment_strategy" => "prompt_append",
        "content" => prompt_body(document, chunks),
        "source_document" => {
          "title" => document.title,
          "filename" => document.source_name,
          "page_count" => document.page_count
        }
      }
    end

    def review_metadata_for(document, chunks)
      {
        "imported_from_pdf" => true,
        "filename" => document.source_name,
        "page_count" => document.page_count,
        "chunk_count" => chunks.count,
        "imported_by_user_id" => actor&.id
      }
    end

    def prompt_body(document, chunks)
      summary_lines = chunks
        .select { |chunk| chunk[:chunk_type] == "summary" }
        .first(12)
        .map { |chunk| "- #{chunk[:content]}" }

      body_lines = []
      body_lines << "Reference material: #{document.title}"
      body_lines << "Imported from #{document.source_name} (#{document.page_count} pages)."
      body_lines << ""
      body_lines << "Use this material as authoritative guidance when it is relevant to the task."
      body_lines << ""
      body_lines << "Key excerpts:"
      body_lines.concat(summary_lines.presence || fallback_lines(document))

      body_lines.join("\n").strip
    end

    def fallback_lines(document)
      document.pages.first(5).map do |page|
        "- Page #{page.fetch(:number)}: #{page.fetch(:text).tr("\n", " ").truncate(220)}"
      end
    end
  end
end
