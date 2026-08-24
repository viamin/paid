# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::RuntimeImageSelector do
  def project_double(test_languages: [], detected_languages: [], detected_language: nil)
    instance_double(
      Project,
      test_languages: test_languages,
      detected_languages: detected_languages,
      detected_language: detected_language
    ).tap do |dbl|
      allow(dbl).to receive(:respond_to?).with(:test_languages).and_return(true)
      allow(dbl).to receive(:respond_to?).with(:detected_languages).and_return(true)
      allow(dbl).to receive(:respond_to?).with(:detected_language).and_return(true)
    end
  end

  let(:production_env) { ActiveSupport::StringInquirer.new("production") }
  let(:development_env) { ActiveSupport::StringInquirer.new("development") }
  let(:catalog) do
    Containers::RuntimeImageCatalog.new(
      "registry" => "ghcr.io",
      "repository" => "acme/paid-agent",
      "profiles" => {
        "paid-agent:latest" => {
          "default_reference" => "base-amd64-2026-08-17",
          "identities" => {
            "base-amd64-2026-08-17" => {
              "digest" => "sha256:#{'1' * 64}",
              "architecture" => "amd64",
              "status" => "active"
            },
            "base-amd64-2026-08-10" => {
              "digest" => "sha256:#{'2' * 64}",
              "architecture" => "amd64",
              "status" => "active"
            },
            "base-amd64-2026-08-01" => {
              "digest" => "sha256:#{'3' * 64}",
              "architecture" => "amd64",
              "status" => "deprecated"
            },
            "base-amd64-2026-07-28" => {
              "digest" => "sha256:#{'4' * 64}",
              "architecture" => "amd64",
              "status" => "blocked"
            }
          }
        }
      }
    )
  end

  describe ".select" do
    it "keeps the mutable latest tag for local development" do
      result = described_class.select(
        project: project_double(detected_language: "ruby"),
        environment: development_env,
        catalog: catalog
      )

      expect(result.image).to eq("paid-agent:latest")
      expect(result.metadata).to include(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "paid-agent:latest",
        "digest" => nil,
        "provenance_reference" => "mutable:paid-agent:latest"
      )
    end

    it "resolves production runs to the active immutable digest" do
      result = described_class.select(
        project: project_double(detected_language: "ruby"),
        environment: production_env,
        catalog: catalog
      )

      expect(result.image).to eq("ghcr.io/acme/paid-agent@sha256:#{'1' * 64}")
      expect(result.metadata).to include(
        "requested_image" => "paid-agent:latest",
        "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{'1' * 64}",
        "digest" => "sha256:#{'1' * 64}",
        "architecture" => "amd64",
        "registry" => "ghcr.io",
        "repository" => "acme/paid-agent",
        "provenance_reference" => "base-amd64-2026-08-17"
      )
    end

    it "allows rollback to a prior active digest without moving latest" do
      result = described_class.select(
        requested_image: "paid-agent:latest",
        environment: production_env,
        catalog: catalog,
        provenance_reference: "base-amd64-2026-08-10"
      )

      expect(result.image).to eq("ghcr.io/acme/paid-agent@sha256:#{'2' * 64}")
      expect(result.provenance_reference).to eq("base-amd64-2026-08-10")
    end

    it "rejects deprecated image identities for new production runs" do
      expect {
        described_class.select(
          requested_image: "paid-agent:latest",
          environment: production_env,
          catalog: catalog,
          provenance_reference: "base-amd64-2026-08-01"
        )
      }.to raise_error(Containers::RuntimeImageCatalog::InactiveImageError, /deprecated/)
    end

    it "rejects blocked image identities for new production runs" do
      expect {
        described_class.select(
          requested_image: "paid-agent:latest",
          environment: production_env,
          catalog: catalog,
          provenance_reference: "base-amd64-2026-07-28"
        )
      }.to raise_error(Containers::RuntimeImageCatalog::InactiveImageError, /blocked/)
    end
  end

  describe "Result.from_metadata" do
    it "round-trips persisted metadata back into an equivalent selection" do
      selection = described_class.select(
        requested_image: "paid-agent:latest",
        environment: production_env,
        catalog: catalog
      )

      rebuilt = described_class::Result.from_metadata(selection.metadata)

      expect(rebuilt.metadata).to eq(selection.metadata)
      expect(rebuilt.image).to eq(selection.image)
      expect(rebuilt.provenance_reference).to eq(selection.provenance_reference)
    end
  end
end
