# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::TraceArtifactExporter do
  subject(:service) do
    described_class.new(
      storage: storage,
      org: "acme",
      repo: "web",
      pr_number: 42,
      commit_sha: "abc1234def5678",
      route_name: "homepage",
      frames: frames,
      logger: logger,
      log_message: "screenshots.export_failed",
      log_context: { project_id: 12, agent_run_id: 34 }
    )
  end

  let(:storage) { instance_double(Screenshots::Storage) }
  let(:logger) { instance_double(ActiveSupport::Logger, warn: true) }
  let(:gif_artifact) do
    {
      "lane" => "object_storage",
      "kind" => "trace_gif",
      "content_type" => "image/gif",
      "locator" => {
        "key" => "screenshots/acme/web/pr-42/abc1234def5678/homepage.gif",
        "url" => "https://s3.example.com/homepage.gif"
      },
      "metadata" => {
        "route_name" => "homepage",
        "filename" => "homepage.gif"
      }
    }
  end
  let(:video_artifact) do
    {
      "lane" => "object_storage",
      "kind" => "trace_video",
      "content_type" => "video/webm",
      "locator" => {
        "key" => "screenshots/acme/web/pr-42/abc1234def5678/homepage.webm",
        "url" => "https://s3.example.com/homepage.webm"
      },
      "metadata" => {
        "route_name" => "homepage",
        "filename" => "homepage.webm"
      }
    }
  end

  before do
    allow(storage).to receive(:artifact_key) do |route_name:, extension:, **|
      "screenshots/acme/web/pr-42/abc1234def5678/#{route_name}#{extension}"
    end
  end

  describe "#call" do
    context "with a single static screenshot frame" do
      let(:frames) { [ "/tmp/screenshots/homepage.png" ] }

      it "skips export and returns no artifacts" do
        allow(Screenshots::TraceToVideo).to receive(:call)
        allow(Screenshots::TraceToGif).to receive(:call)
        allow(storage).to receive(:upload_artifact)

        expect(service.call).to eq({})
        expect(Screenshots::TraceToVideo).not_to have_received(:call)
        expect(Screenshots::TraceToGif).not_to have_received(:call)
        expect(storage).not_to have_received(:upload_artifact)
      end
    end

    context "with multi-frame capture input" do
      let(:frames) do
        [
          "/tmp/screenshots/homepage-0001.png",
          "/tmp/screenshots/homepage-0002.png"
        ]
      end

      before do
        allow(Screenshots::TraceToVideo).to receive(:call) do |output_path:, **|
          File.write(output_path, "fake webm")
          output_path
        end
        allow(Screenshots::TraceToGif).to receive(:call) do |output_path:, **|
          File.write(output_path, "GIF89a")
          output_path
        end
        allow(storage).to receive(:upload_artifact) do |file_path:, route_name:, **|
          "https://s3.example.com/#{route_name}#{File.extname(file_path)}"
        end
      end

      it "exports and uploads GIF and video artifacts" do
        expect(service.call).to eq(
          gif_url: "https://s3.example.com/homepage.gif",
          gif_artifact: gif_artifact,
          video_url: "https://s3.example.com/homepage.webm",
          video_filename: "homepage.webm",
          video_artifact: video_artifact
        )

        expect(Screenshots::TraceToVideo).to have_received(:call).with(
          hash_including(frames: frames)
        )
        expect(Screenshots::TraceToGif).to have_received(:call).with(
          hash_including(frames: frames)
        )
        expect(storage).to have_received(:upload_artifact).twice
      end
    end

    context "with a Playwright trace input" do
      let(:trace_path) { File.join(Dir.mktmpdir("trace-export-spec"), "homepage.trace.zip") }

      before do
        File.write(trace_path, "fake trace zip")
        allow(Screenshots::TraceToVideo).to receive(:call) do |output_path:, **|
          File.write(output_path, "fake webm")
          output_path
        end
        allow(Screenshots::TraceToGif).to receive(:call) do |output_path:, **|
          File.write(output_path, "GIF89a")
          output_path
        end
        allow(storage).to receive(:upload_artifact) do |file_path:, route_name:, **|
          "https://s3.example.com/#{route_name}#{File.extname(file_path)}"
        end
      end

      def export_from_trace
        described_class.new(
          storage: storage,
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: "abc1234def5678",
          route_name: "homepage",
          trace_path: trace_path,
          logger: logger,
          log_message: "screenshots.export_failed",
          log_context: { project_id: 12, agent_run_id: 34 }
        ).call
      end

      it "exports and uploads GIF and video artifacts from the trace" do
        expect(export_from_trace).to eq(
          gif_url: "https://s3.example.com/homepage.gif",
          gif_artifact: gif_artifact,
          video_url: "https://s3.example.com/homepage.webm",
          video_filename: "homepage.webm",
          video_artifact: video_artifact
        )
      end

      it "converts the trace through the trace-aware converters" do
        export_from_trace

        expect(Screenshots::TraceToVideo).to have_received(:call)
          .with(hash_including(trace_path: trace_path))
        expect(Screenshots::TraceToGif).to have_received(:call)
          .with(hash_including(trace_path: trace_path))
      end
    end

    context "when conversion fails" do
      let(:frames) do
        [
          "/tmp/screenshots/homepage-0001.png",
          "/tmp/screenshots/homepage-0002.png"
        ]
      end

      before do
        allow(Screenshots::TraceToVideo).to receive(:call)
          .and_raise(Screenshots::TraceToVideo::ConversionError, "ffmpeg missing")
      end

      it "logs and falls back to static publishing" do
        expect(service.call).to eq({})
        expect(logger).to have_received(:warn).with(
          hash_including(
            message: "screenshots.export_failed",
            project_id: 12,
            agent_run_id: 34,
            route_name: "homepage",
            error: "ffmpeg missing"
          )
        )
      end
    end

    context "when GIF conversion fails after video export succeeds" do
      let(:frames) do
        [
          "/tmp/screenshots/homepage-0001.png",
          "/tmp/screenshots/homepage-0002.png"
        ]
      end

      before do
        allow(Screenshots::TraceToVideo).to receive(:call) do |output_path:, **|
          File.write(output_path, "fake webm")
          output_path
        end
        allow(Screenshots::TraceToGif).to receive(:call)
          .and_raise(Screenshots::TraceToGif::ConversionError, "gifski missing")
        allow(storage).to receive(:upload_artifact) do |file_path:, route_name:, **|
          "https://s3.example.com/#{route_name}#{File.extname(file_path)}"
        end
      end

      it "keeps the uploaded video artifact and logs the GIF failure" do
        expect(service.call).to eq(
          video_url: "https://s3.example.com/homepage.webm",
          video_filename: "homepage.webm",
          video_artifact: video_artifact
        )

        expect(storage).to have_received(:upload_artifact).once
        expect(logger).to have_received(:warn).with(
          hash_including(
            message: "screenshots.export_failed",
            project_id: 12,
            agent_run_id: 34,
            route_name: "homepage",
            error: "gifski missing"
          )
        )
      end
    end
  end
end
