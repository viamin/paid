# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ImageResolver do
  # A lightweight stand-in for Project that exposes only the normalized repo-
  # profile API the resolver reads. Keeps the spec fast and behavior-focused.
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

  describe ".base_image" do
    it "exposes the base image tag in one place" do
      expect(described_class.base_image).to eq("paid-agent:latest")
    end
  end

  describe "constants" do
    it "defines the base image" do
      expect(described_class::BASE_IMAGE).to eq("paid-agent:latest")
    end

    it "lists base runtimes bundled in the base image" do
      expect(described_class::BASE_LANGUAGES).to contain_exactly("node", "python", "ruby")
    end

    it "lists extended runtimes that need combo layers" do
      expect(described_class::EXTENDED_LANGUAGES).to contain_exactly("elixir", "go", "rust", "swift")
    end

    it "covers the full RDR-046 target language matrix" do
      expect(described_class::SUPPORTED_LANGUAGES).to contain_exactly(
        "ruby", "javascript", "typescript", "python", "go", "rust", "elixir", "swift"
      )
    end

    it "maps JavaScript and TypeScript to the node token" do
      expect(described_class::LANGUAGE_TOKENS["javascript"]).to eq("node")
      expect(described_class::LANGUAGE_TOKENS["typescript"]).to eq("node")
    end
  end

  describe ".resolve — base image" do
    it "resolves to the base image when no language is detected" do
      expect(described_class.resolve(project_double)).to eq("paid-agent:latest")
    end

    it "resolves Ruby to the base image" do
      project = project_double(detected_language: "ruby")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "resolves JavaScript to the base image" do
      project = project_double(detected_language: "javascript")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "resolves TypeScript to the base image" do
      project = project_double(detected_language: "typescript")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "resolves Python to the base image" do
      project = project_double(detected_language: "python")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "resolves a base-only polyglot set to the base image" do
      project = project_double(detected_languages: %w[ruby javascript python])
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "resolves Ruby + TypeScript (both node/ruby) to the base image" do
      project = project_double(detected_languages: %w[typescript ruby])
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "is case-insensitive and ignores whitespace" do
      project = project_double(detected_language: "  RuBy  ")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end
  end

  describe ".resolve — combo images" do
    it "resolves Go to a Go combo image" do
      project = project_double(detected_language: "go")
      expect(described_class.resolve(project)).to eq("paid-agent:go")
    end

    it "resolves Rust to a Rust combo image" do
      project = project_double(detected_language: "rust")
      expect(described_class.resolve(project)).to eq("paid-agent:rust")
    end

    it "resolves Elixir to an Elixir combo image" do
      project = project_double(detected_language: "elixir")
      expect(described_class.resolve(project)).to eq("paid-agent:elixir")
    end

    it "resolves Swift to a Swift combo image" do
      project = project_double(detected_language: "swift")
      expect(described_class.resolve(project)).to eq("paid-agent:swift")
    end

    it "includes base runtimes in a polyglot combo tag, sorted deterministically" do
      project = project_double(detected_languages: %w[elixir javascript ruby python])
      expect(described_class.resolve(project)).to eq("paid-agent:elixir-node-python-ruby")
    end

    it "uses test_languages when present" do
      project = project_double(test_languages: %w[go], detected_languages: %w[go ruby])
      expect(described_class.resolve(project)).to eq("paid-agent:go")
    end

    it "is deterministic regardless of input order" do
      a = project_double(detected_languages: %w[ruby go javascript])
      b = project_double(detected_languages: %w[javascript go ruby])
      expect(described_class.resolve(a)).to eq(described_class.resolve(b))
    end
  end

  describe ".resolve — unsupported runtimes" do
    it "falls back to the base image for an unsupported primary language by default" do
      project = project_double(detected_language: "java")
      expect(described_class.resolve(project)).to eq("paid-agent:latest")
    end

    it "exposes the unsupported languages on the instance" do
      resolver = described_class.new(project_double(detected_languages: %w[ruby java]))
      resolver.resolve
      expect(resolver.unsupported_languages).to contain_exactly("java")
    end

    it "still resolves the extended portion of a polyglot set with an unknown language" do
      project = project_double(detected_languages: %w[go java])
      expect(described_class.resolve(project)).to eq("paid-agent:go")
    end

    context "when in strict mode" do
      it "raises when a detected language is unsupported" do
        project = project_double(detected_language: "kotlin")
        expect {
          described_class.resolve(project, strict: true)
        }.to raise_error(described_class::UnsupportedRuntimeError, /kotlin/)
      end

      it "lists the unsupported languages in the error" do
        project = project_double(detected_languages: %w[ruby haskell clojure])
        expect {
          described_class.resolve(project, strict: true)
        }.to raise_error(described_class::UnsupportedRuntimeError) do |error|
          expect(error.languages).to contain_exactly("clojure", "haskell")
        end
      end

      it "does not raise for a fully supported language set" do
        project = project_double(detected_languages: %w[elixir ruby])
        expect {
          described_class.resolve(project, strict: true)
        }.not_to raise_error
      end
    end
  end
end
