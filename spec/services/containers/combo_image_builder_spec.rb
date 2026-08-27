# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ComboImageBuilder do
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:base_image) { instance_double(Docker::Image, id: "sha256:#{'b' * 64}") }
  let(:built_image) { instance_double(Docker::Image, id: "sha256:#{'a' * 64}") }

  def combo_image(labels: {})
    instance_double(Docker::Image, info: { "Labels" => labels })
  end

  def stub_base_present
    allow(backend).to receive(:get_image).with(Containers::ImageResolver::BASE_IMAGE).and_return(base_image)
  end

  def stub_combo_absent(image)
    allow(backend).to receive(:get_image).with(image).and_raise(Docker::Error::NotFoundError.new("not found"))
  end

  before do
    stub_base_present
    allow(Rails.logger).to receive(:public_send)
  end

  describe ".ensure_available — ownership" do
    it "returns nil for the base image" do
      expect(described_class.ensure_available("paid-agent:latest", backend: backend)).to be_nil
      expect(backend).not_to have_received(:get_image)
    end

    it "returns nil for non-paid-agent references" do
      expect(described_class.ensure_available("ubuntu:24.04", backend: backend)).to be_nil
      expect(described_class.ensure_available("ghcr.io/acme/paid-agent@sha256:#{'d' * 64}", backend: backend)).to be_nil
      expect(backend).not_to have_received(:get_image)
    end
  end

  describe ".ensure_available — build-on-first-use" do
    # @spec POLYGLOT-TEST-007
    it "builds a missing single-layer combo from the language dockerfile and tags it" do
      stub_combo_absent("paid-agent:go")
      allow(backend).to receive(:build_image).and_return(built_image)

      result = described_class.ensure_available("paid-agent:go", backend: backend)

      expect(result.status).to eq(:built)
      expect(result.image).to eq("paid-agent:go")
      expect(backend).to have_received(:build_image).with(
        /# Go language layer/, hash_including(
          t: "paid-agent:go",
          buildargs: { "BASE_IMAGE" => "paid-agent:latest" }.to_json,
          labels: hash_including(described_class::BASE_DIGEST_LABEL => base_image.id)
        )
      )
    end

    # @spec POLYGLOT-TEST-007
    it "reuses an existing, current combo without rebuilding" do
      allow(backend).to receive(:get_image).with("paid-agent:go").and_return(
        combo_image(labels: { described_class::BASE_DIGEST_LABEL => base_image.id })
      )

      result = described_class.ensure_available("paid-agent:go", backend: backend)

      expect(result.status).to eq(:existing)
      expect(backend).not_to have_received(:build_image)
    end

    it "chains multi-runtime layers by tag, not build id, so multi-node backends build correctly" do
      stub_combo_absent("paid-agent:go-rust")
      # Mimics a multi-node backend (e.g. swarm), which returns one image per
      # node from build_image rather than a single image.
      per_node_images = [ instance_double(Docker::Image, id: "sha256:#{'1' * 64}"), instance_double(Docker::Image, id: "sha256:#{'2' * 64}") ]
      allow(backend).to receive(:build_image).and_return(per_node_images)

      described_class.ensure_available("paid-agent:go-rust", backend: backend)

      intermediate_tag = "paid-agent-build:go-rust--layer0"
      expect(backend).to have_received(:build_image).with(
        /# Go language layer/, hash_including(
          t: intermediate_tag,
          buildargs: { "BASE_IMAGE" => "paid-agent:latest" }.to_json
        )
      ).once
      expect(backend).to have_received(:build_image).with(
        /# Rust language layer/, hash_including(
          t: "paid-agent:go-rust",
          buildargs: { "BASE_IMAGE" => intermediate_tag }.to_json
        )
      ).once
    end

    it "rebuilds a polyglot combo including base-language tokens" do
      stub_combo_absent("paid-agent:elixir-node-python-ruby")
      allow(backend).to receive(:build_image).and_return(built_image)

      result = described_class.ensure_available("paid-agent:elixir-node-python-ruby", backend: backend)

      expect(result.status).to eq(:built)
      expect(backend).to have_received(:build_image).with(
        /# Elixir language layer/, hash_including(t: "paid-agent:elixir-node-python-ruby")
      )
    end

    it "logs build start and success with duration" do
      stub_combo_absent("paid-agent:swift")
      allow(backend).to receive(:build_image).and_return(built_image)

      expect(Rails.logger).to receive(:public_send).with(
        :info, hash_including(message: "agent_image.build.start", image: "paid-agent:swift")
      )
      expect(Rails.logger).to receive(:public_send).with(
        :info, hash_including(message: "agent_image.build.success", image: "paid-agent:swift", duration_ms: kind_of(Integer))
      )

      described_class.ensure_available("paid-agent:swift", backend: backend)
    end
  end

  describe ".ensure_available — cache invalidation" do
    # @spec POLYGLOT-TEST-009
    it "rebuilds a combo whose recorded base digest no longer matches the base image" do
      allow(backend).to receive(:get_image).with("paid-agent:go").and_return(
        combo_image(labels: { described_class::BASE_DIGEST_LABEL => "sha256:#{'0' * 64}" })
      )
      allow(backend).to receive(:build_image).and_return(built_image)

      result = described_class.ensure_available("paid-agent:go", backend: backend)

      expect(result.status).to eq(:rebuilt)
      expect(backend).to have_received(:build_image).once
    end

    # @spec POLYGLOT-TEST-009
    it "rebuilds an unlabelled combo (built outside the builder)" do
      allow(backend).to receive(:get_image).with("paid-agent:go").and_return(combo_image(labels: {}))

      allow(backend).to receive(:build_image).and_return(built_image)

      expect(described_class.ensure_available("paid-agent:go", backend: backend).status).to eq(:rebuilt)
    end

    it "force_rebuild bypasses the existence check" do
      allow(backend).to receive(:get_image).with("paid-agent:go").and_return(
        combo_image(labels: { described_class::BASE_DIGEST_LABEL => base_image.id })
      )
      allow(backend).to receive(:build_image).and_return(built_image)

      described_class.force_rebuild("paid-agent:go", backend: backend)

      expect(backend).to have_received(:build_image).with(
        anything, hash_including(nocache: "1")
      )
    end
  end

  describe ".ensure_available — loud failures" do
    # @spec POLYGLOT-TEST-008
    it "rejects tags with unknown runtime tokens" do
      expect {
        described_class.ensure_available("paid-agent:java", backend: backend)
      }.to raise_error(described_class::UnbuildableImageError, /java/)
    end

    # @spec POLYGLOT-TEST-008
    it "rejects base-only tags that carry no extended runtime layer" do
      expect {
        described_class.ensure_available("paid-agent:node-ruby", backend: backend)
      }.to raise_error(described_class::UnbuildableImageError, /no extended runtime/)
    end

    # @spec POLYGLOT-TEST-008
    it "fails with an actionable error when the base image is missing" do
      allow(backend).to receive(:get_image).with(Containers::ImageResolver::BASE_IMAGE)
        .and_raise(Docker::Error::NotFoundError.new("no such image"))
      stub_combo_absent("paid-agent:go")

      expect {
        described_class.ensure_available("paid-agent:go", backend: backend)
      }.to raise_error(described_class::MissingBaseImageError, /build-agent-image\.sh/)
    end

    # @spec POLYGLOT-TEST-008
    it "wraps docker build failures with the build output tail" do
      stub_combo_absent("paid-agent:go")
      allow(backend).to receive(:build_image) do |*_args, &block|
        block&.call("{\"stream\":\"step 1/2 ok\"}\n")
        block&.call("{\"stream\":\"E: unable to fetch packages\"}\n")
        raise Docker::Error::ServerError, "returned non-zero code"
      end

      expect {
        described_class.ensure_available("paid-agent:go", backend: backend)
      }.to raise_error(described_class::BuildError, a_string_including("paid-agent:go", "unable to fetch packages"))
    end

    it "rejects a tag whose language dockerfile is missing" do
      stub_combo_absent("paid-agent:go")
      allow(described_class).to receive(:languages_dir).and_return(Pathname.new(Dir.mktmpdir("empty-layers")))

      expect {
        described_class.ensure_available("paid-agent:go", backend: backend)
      }.to raise_error(described_class::UnbuildableImageError, /No language layer Dockerfile/)
    end

    it "logs build failures" do
      stub_combo_absent("paid-agent:go")
      allow(backend).to receive(:build_image).and_raise(Docker::Error::ServerError.new("boom"))

      expect(Rails.logger).to receive(:public_send).with(
        :error, hash_including(message: "agent_image.build.failed", image: "paid-agent:go")
      )

      expect {
        described_class.ensure_available("paid-agent:go", backend: backend)
      }.to raise_error(described_class::BuildError)
    end
  end

  describe ".combo_images" do
    it "lists paid-agent combo tags with their labels" do
      combo = instance_double(Docker::Image, id: "sha256:#{'c' * 64}", info: {
        "RepoTags" => [ "paid-agent:go", "paid-agent:latest" ],
        "Labels" => { described_class::BUILT_AT_LABEL => "2026-08-01T00:00:00Z" }
      })
      foreign = instance_double(Docker::Image, id: "sha256:#{'f' * 64}", info: {
        "RepoTags" => [ "ubuntu:24.04" ], "Labels" => {}
      })
      allow(backend).to receive(:list_images).and_return([ combo, foreign ])

      entries = described_class.combo_images(backend: backend)

      expect(entries).to contain_exactly(
        hash_including(image: "paid-agent:go", id: "sha256:#{'c' * 64}")
      )
    end
  end
end
