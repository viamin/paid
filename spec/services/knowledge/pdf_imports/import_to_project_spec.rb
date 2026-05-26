# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::PdfImports::ImportToProject do
  include ActiveJob::TestHelper

  let(:account) { create(:account, plan: "professional") }
  let(:project) { create(:project, account: account) }
  let(:actor) { create(:user, :admin, account: account) }
  let(:file) do
    instance_double(
      ActionDispatch::Http::UploadedFile,
      original_filename: "modern_css.pdf",
      content_type: "application/pdf",
      size: 1.megabyte
    )
  end
  let(:document) do
    Knowledge::PdfImports::Parser::ParsedDocument.new(
      title: "Modern CSS",
      page_count: 2,
      source_name: "modern_css.pdf",
      pages: [
        { number: 1, text: "Page one text" },
        { number: 2, text: "Page two text" }
      ]
    )
  end
  let(:chunks) do
    [
      { chunk_type: "context", content: "Page 1\nGrid guidance", sequence: 0, scope_tags: [ "pdf_import", "page_1" ] },
      { chunk_type: "summary", content: "page 1: Grid guidance", sequence: 1, scope_tags: [ "pdf_import", "page_1" ] }
    ]
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(Knowledge::PdfImports::Parser).to receive(:call).and_return(document)
    allow(Knowledge::PdfImports::Chunker).to receive(:call).and_return(chunks)
  end

  it "stores a reference document artifact, chunks, and enqueues embeddings" do
    expect {
      described_class.call(project: project, file: file, actor: actor)
    }.to change(KnowledgeArtifact, :count).by(1)
      .and change(KnowledgeChunk, :count).by(2)
      .and change(CollectorRun, :count).by(1)

    artifact = project.knowledge_artifacts.order(:id).last

    expect(artifact.artifact_type).to eq("reference_document")
    expect(artifact.identifier).to eq("Modern CSS")
    expect(artifact.metadata).to include("page_count" => 2, "source_name" => "modern_css.pdf")
    expect(project.reload.knowledge_status).to eq("ready")
    expect(enqueued_jobs.map { |job| job[:job] }).to include(EmbedChunksJob)
  end

  it "rejects non-paid plans" do
    project.account.update!(plan: "trial")

    expect {
      described_class.call(project: project, file: file, actor: actor)
    }.to raise_error(Knowledge::PdfImports::ImportError, /available on professional and enterprise plans/)
  end

  it "rejects oversized PDFs" do
    allow(file).to receive(:size).and_return(51.megabytes)

    expect {
      described_class.call(project: project, file: file, actor: actor)
    }.to raise_error(Knowledge::PdfImports::ImportError, "PDF must be smaller than 50 MB.")
  end
end
