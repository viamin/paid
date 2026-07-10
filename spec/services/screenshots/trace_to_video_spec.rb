# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::TraceToVideo do
  let(:tmpdir) { Dir.mktmpdir("trace-to-video-spec-") }
  let(:output_path) { File.join(tmpdir, "demo.webm") }
  let(:logger) { instance_double(Logger, info: nil) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe ".configured?" do
    it "returns true when ffmpeg is on PATH" do
      allow(Open3).to receive(:capture3).with("ffmpeg", "-version").and_return([ "ffmpeg version", "", instance_double(Process::Status, success?: true) ])

      expect(described_class.configured?).to be true
    end

    it "returns false when ffmpeg is missing" do
      allow(Open3).to receive(:capture3).with("ffmpeg", "-version").and_raise(Errno::ENOENT)

      expect(described_class.configured?).to be false
    end

    it "returns false when ffmpeg exits with non-zero status" do
      allow(Open3).to receive(:capture3).with("ffmpeg", "-version").and_return([ "", "boom", instance_double(Process::Status, success?: false) ])

      expect(described_class.configured?).to be false
    end
  end

  describe "argument validation" do
    it "raises when no frame source is provided" do
      expect {
        described_class.new(output_path: output_path)
      }.to raise_error(ArgumentError, /exactly one/)
    end

    it "raises when more than one frame source is provided" do
      expect {
        described_class.new(frames_dir: tmpdir, frames: [], output_path: output_path)
      }.to raise_error(ArgumentError, /exactly one/)
    end

    it "raises when output_path is blank" do
      expect {
        described_class.new(frames: [], output_path: "")
      }.to raise_error(ArgumentError, /output_path/)
    end

    it "raises when framerate is not positive" do
      expect {
        described_class.new(frames: [], output_path: output_path, framerate: 0)
      }.to raise_error(ArgumentError, /framerate/)
    end
  end

  describe "#call" do
    let(:frames) do
      [
        write_png(File.join(tmpdir, "frame-1.png")),
        write_png(File.join(tmpdir, "frame-2.png"))
      ]
    end

    let(:ffmpeg_success) { instance_double(Process::Status, success?: true) }
    let(:ffmpeg_failure) { instance_double(Process::Status, success?: false, exitstatus: 1) }

    before do
      allow(described_class).to receive(:configured?).and_return(true)
    end

    it "returns the output path when conversion succeeds" do
      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffmpeg"
          File.write(output_path, "fake webm data")
          [ "", "", ffmpeg_success ]
        end
      end

      result = described_class.call(frames: frames, output_path: output_path, logger: logger)

      expect(result).to eq(output_path)
      expect(File.exist?(output_path)).to be true
    end

    it "raises ConversionError when ffmpeg is not installed" do
      allow(described_class).to receive(:configured?).and_return(false)

      expect {
        described_class.call(frames: frames, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /ffmpeg/)
    end

    it "raises ConversionError when ffmpeg exits non-zero" do
      allow(Open3).to receive(:capture3) do |*cmd|
        next [ "", "conversion failed", ffmpeg_failure ] if cmd.first == "ffmpeg"
      end

      expect {
        described_class.call(frames: frames, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /ffmpeg failed/)
    end

    it "invokes ffmpeg with the expected codec options" do
      captured_cmd = nil

      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffmpeg"
          captured_cmd = cmd
          File.write(output_path, "fake webm")
          [ "", "", ffmpeg_success ]
        end
      end

      described_class.call(frames: frames, output_path: output_path, framerate: 24)

      expect(captured_cmd).to include("ffmpeg", "-y", "-framerate", "24")
      expect(captured_cmd.any? { |arg| arg.include?("%05d.png") }).to be true
      expect(captured_cmd).to include("-c:v", "libvpx-vp9")
    end

    it "raises ArgumentError when a frame path does not exist" do
      expect {
        described_class.call(frames: [ "/tmp/does-not-exist.png" ], output_path: output_path)
      }.to raise_error(ArgumentError, /frame not found/)
    end

    it "extracts embedded PNGs from a Playwright trace zip when given trace_path" do
      trace_zip = File.join(tmpdir, "trace.zip")
      File.write(trace_zip, "")

      allow(Open3).to receive(:capture3) do |*cmd|
        case cmd.first
        when "ffmpeg"
          File.write(output_path, "fake webm")
          [ "", "", ffmpeg_success ]
        when "unzip"
          dest_index = cmd.index("-d") + 1
          dest_dir = cmd[dest_index]
          FileUtils.mkdir_p(dest_dir)
          %w[trace-0.png trace-1.png].each_with_index do |name, idx|
            File.binwrite(File.join(dest_dir, name), "\x89PNG\r\n\x1a\nfake-#{idx}")
          end
          [ "", "", ffmpeg_success ]
        end
      end

      described_class.call(trace_path: trace_zip, output_path: output_path)

      expect(File.exist?(output_path)).to be true
    end

    it "raises ConversionError when a trace zip contains no PNGs" do
      trace_zip = File.join(tmpdir, "empty.zip")
      File.write(trace_zip, "")

      allow(Open3).to receive(:capture3) do |*cmd|
        case cmd.first
        when "unzip"
          dest_index = cmd.index("-d") + 1
          dest_dir = cmd[dest_index]
          FileUtils.mkdir_p(dest_dir)
          File.write(File.join(dest_dir, "metadata.json"), "{}")
          [ "", "", ffmpeg_success ]
        end
      end

      expect {
        described_class.call(trace_path: trace_zip, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /no PNG frames/)
    end

    it "raises ArgumentError when trace file does not exist" do
      expect {
        described_class.call(trace_path: "/tmp/missing-trace.zip", output_path: output_path)
      }.to raise_error(ArgumentError, /trace file not found/)
    end

    it "raises ConversionError when unzip fails" do
      trace_zip = File.join(tmpdir, "broken.zip")
      File.write(trace_zip, "")

      status = instance_double(Process::Status, success?: false, exitstatus: 9)
      allow(Open3).to receive(:capture3) do |*cmd|
        next [ "", "unzip error", status ] if cmd.first == "unzip"
      end

      expect {
        described_class.call(trace_path: trace_zip, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /unzip failed/)
    end

    it "logs a structured info event after successful conversion" do
      allow(Open3).to receive(:capture3) do |*cmd|
        if cmd.first == "ffmpeg"
          File.write(output_path, "fake webm")
          [ "", "", ffmpeg_success ]
        end
      end

      described_class.call(frames: frames, output_path: output_path, logger: logger, framerate: 6)

      expect(logger).to have_received(:info).with(
        hash_including(message: "screenshots.trace_to_video.converted", framerate: 6)
      )
    end
  end

  def write_png(path)
    File.binwrite(path, "\x89PNG\r\n\x1a\nfake-png-bytes")
    path
  end
end
