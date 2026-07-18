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

    it "renumbers lexicographically ordered frames from frames_dir before invoking ffmpeg" do
      frames_dir = File.join(tmpdir, "frames-dir")
      FileUtils.mkdir_p(frames_dir)
      write_png(File.join(frames_dir, "frame-10.png"))
      write_png(File.join(frames_dir, "frame-2.png"))

      ordered_entries = nil
      allow(Open3).to receive(:capture3) do |*cmd|
        next nil unless cmd.first == "ffmpeg"

        pattern = cmd[cmd.index("-i") + 1]
        ordered_entries = Dir.children(File.dirname(pattern)).sort
        File.write(output_path, "fake webm data")
        [ "", "", ffmpeg_success ]
      end

      described_class.call(frames_dir: frames_dir, output_path: output_path, logger: logger)

      expect(ordered_entries).to include("00001.png", "00002.png")
    end

    it "raises ConversionError when frames_dir contains no PNGs" do
      frames_dir = File.join(tmpdir, "empty-frames-dir")
      FileUtils.mkdir_p(frames_dir)

      expect {
        described_class.call(frames_dir: frames_dir, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /contains no PNG frames/)
    end

    it "replays Playwright trace resources in screencast metadata order" do
      trace_zip = File.join(tmpdir, "trace.zip")
      File.write(trace_zip, "")

      ordered_entries = stub_trace_unzip_and_ffmpeg(
        trace_zip,
        [
          { "sha1" => "b-frame", "timestamp" => 2000, "body" => "frame-two" },
          { "sha1" => "a-frame", "timestamp" => 1000, "body" => "frame-one" }
        ]
      )

      described_class.call(trace_path: trace_zip, output_path: output_path)

      expect(File.exist?(output_path)).to be true
      expect(frame_payloads(ordered_entries.call)).to eq([ "frame-one", "frame-two" ])
    end

    it "raises ConversionError when trace metadata has no screencast frames" do
      trace_zip = File.join(tmpdir, "empty.zip")
      File.write(trace_zip, "")

      allow(Open3).to receive(:capture3) do |*cmd|
        case cmd.first
        when "unzip"
          write_trace_fixture(cmd[cmd.index("-d") + 1], events: [ { "type" => "context-options" } ])
          [ "", "", ffmpeg_success ]
        end
      end

      expect {
        described_class.call(trace_path: trace_zip, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /contains no screencast frames/)
    end

    it "raises ConversionError when trace metadata references a missing resource" do
      trace_zip = File.join(tmpdir, "missing-resource.zip")
      File.write(trace_zip, "")

      allow(Open3).to receive(:capture3) do |*cmd|
        case cmd.first
        when "unzip"
          write_trace_fixture(
            cmd[cmd.index("-d") + 1],
            frames: [ { "sha1" => "missing-frame", "timestamp" => 1000 } ]
          )
          [ "", "", ffmpeg_success ]
        end
      end

      expect {
        described_class.call(trace_path: trace_zip, output_path: output_path)
      }.to raise_error(Screenshots::TraceToVideo::ConversionError, /missing screencast frame resource/)
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

  def stub_trace_unzip_and_ffmpeg(trace_zip, frames)
    ordered_entries = []
    allow(Open3).to receive(:capture3) do |*cmd|
      case cmd.first
      when "ffmpeg"
        ordered_entries = ordered_png_bodies(cmd[cmd.index("-i") + 1])
        File.write(output_path, "fake webm")
        [ "", "", ffmpeg_success ]
      when "unzip"
        write_trace_fixture(cmd[cmd.index("-d") + 1], frames: frames)
        [ "", "", ffmpeg_success ]
      end
    end

    -> { ordered_entries }
  end

  def ordered_png_bodies(pattern)
    ordered_dir = File.dirname(pattern)

    Dir.children(ordered_dir).sort.filter_map do |entry|
      next unless entry.end_with?(".png")

      File.binread(File.join(ordered_dir, entry))
    end
  end

  def frame_payloads(entries)
    entries.map { |entry| entry.byteslice(8..) }
  end

  def write_trace_fixture(dest_dir, frames: [], events: [])
    FileUtils.mkdir_p(File.join(dest_dir, "resources"))

    frames.each do |frame|
      next unless frame["body"]

      File.binwrite(File.join(dest_dir, "resources", frame.fetch("sha1")), "\x89PNG\r\n\x1a\n#{frame.fetch("body")}")
    end

    trace_events = if events.any?
      events
    else
      [ { "type" => "frame-snapshot", "page.screencastFrames" => frames } ]
    end

    File.write(
      File.join(dest_dir, "trace.trace"),
      trace_events.map { |event| JSON.generate(event) }.join("\n")
    )
  end
end
