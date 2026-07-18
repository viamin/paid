# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::TraceToGif do
  let(:tmpdir) { Dir.mktmpdir("trace-to-gif-spec-") }
  let(:output_path) { File.join(tmpdir, "demo.gif") }
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

    it "raises when width is not positive" do
      expect {
        described_class.new(frames: [], output_path: output_path, width: 0)
      }.to raise_error(ArgumentError, /width/)
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
        next nil unless cmd.first == "ffmpeg"

        File.write(output_path, "GIF89a-fake-data")
        [ "", "", ffmpeg_success ]
      end

      result = described_class.call(frames: frames, output_path: output_path, logger: logger)

      expect(result).to eq(output_path)
      expect(File.exist?(output_path)).to be true
    end

    it "raises ConversionError when ffmpeg is not installed" do
      allow(described_class).to receive(:configured?).and_return(false)

      expect {
        described_class.call(frames: frames, output_path: output_path)
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /ffmpeg/)
    end

    it "raises ConversionError when palettegen fails" do
      allow(Open3).to receive(:capture3) do |*cmd|
        next nil unless cmd.first == "ffmpeg"

        cmd_args = cmd
        # palettegen is the first ffmpeg invocation; it has palettegen in its filter
        if cmd_args.any? { |a| a.include?("palettegen") }
          [ "", "palettegen error", ffmpeg_failure ]
        else
          File.write(output_path, "GIF89a")
          [ "", "", ffmpeg_success ]
        end
      end

      expect {
        described_class.call(frames: frames, output_path: output_path)
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /palettegen failed/)
    end

    it "raises ConversionError when paletteuse fails" do
      allow(Open3).to receive(:capture3) do |*cmd|
        next nil unless cmd.first == "ffmpeg"

        cmd_args = cmd
        if cmd_args.any? { |a| a.include?("palettegen") }
          # palettegen writes a fake palette file
          Dir.glob(File.join(cmd_args[cmd_args.index("-i") + 1].sub("%05d.png", "*"), "*.png")).each do |f|
            File.binwrite(f, "fake palette png") if File.basename(f).include?("palette")
          end
          [ "", "", ffmpeg_success ]
        else
          [ "", "paletteuse error", ffmpeg_failure ]
        end
      end

      expect {
        described_class.call(frames: frames, output_path: output_path)
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /ffmpeg failed/)
    end

    it "raises ConversionError when trace metadata has no screencast frames" do
      trace_zip = File.join(tmpdir, "empty.zip")
      File.write(trace_zip, "")

      allow(Open3).to receive(:capture3) do |*cmd|
        next nil unless cmd.first == "unzip"

        write_trace_fixture(cmd[cmd.index("-d") + 1], events: [ { "type" => "context-options" } ])
        [ "", "", ffmpeg_success ]
      end

      expect {
        described_class.call(trace_path: trace_zip, output_path: output_path)
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /contains no screencast frames/)
    end

    it "replays Playwright trace resources in screencast metadata order" do
      trace_zip = File.join(tmpdir, "trace.zip")
      File.write(trace_zip, "")

      palette_used, gif_exists, ordered_entries = stub_trace_unzip_and_ffmpeg(
        trace_zip,
        [
          { "sha1" => "b-frame", "timestamp" => 2000, "body" => "frame-two" },
          { "sha1" => "a-frame", "timestamp" => 1000, "body" => "frame-one" }
        ],
        output_path
      )

      described_class.call(trace_path: trace_zip, output_path: output_path)

      expect(palette_used.call).to be true
      expect(gif_exists.call).to be true
      expect(frame_payloads(ordered_entries.call)).to eq([ "frame-one", "frame-two" ])
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
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /missing screencast frame resource/)
    end

    it "transcodes a video file when video_path is provided" do
      video_path = File.join(tmpdir, "demo.webm")
      File.write(video_path, "fake video data")

      frame_extracted, gif_exists = stub_video_to_gif(video_path, output_path)

      described_class.call(video_path: video_path, output_path: output_path)

      expect(frame_extracted.call).to be true
      expect(gif_exists.call).to be true
    end

    it "raises ConversionError when video file is missing" do
      expect {
        described_class.call(video_path: "/tmp/missing.webm", output_path: output_path)
      }.to raise_error(ArgumentError, /video file not found/)
    end

    it "raises ArgumentError when trace file does not exist" do
      expect {
        described_class.call(trace_path: "/tmp/missing-trace.zip", output_path: output_path)
      }.to raise_error(ArgumentError, /trace file not found/)
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
        ordered_entries ||= Dir.children(File.dirname(pattern)).sort
        File.write(output_path, "GIF89a-fake-data")
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
      }.to raise_error(Screenshots::TraceToGif::ConversionError, /contains no PNG frames/)
    end

    it "logs a structured info event after successful conversion" do
      allow(Open3).to receive(:capture3) do |*cmd|
        next nil unless cmd.first == "ffmpeg"

        File.write(output_path, "GIF89a")
        [ "", "", ffmpeg_success ]
      end

      described_class.call(frames: frames, output_path: output_path, logger: logger, framerate: 4)

      expect(logger).to have_received(:info).with(
        hash_including(message: "screenshots.trace_to_gif.converted", framerate: 4)
      )
    end
  end

  def write_png(path)
    File.binwrite(path, "\x89PNG\r\n\x1a\nfake-png-bytes")
    path
  end

  def stub_trace_unzip_and_ffmpeg(trace_zip, frames, gif_output_path)
    File.write(trace_zip, "")
    palette_used = false
    ordered_entries = []
    allow(Open3).to receive(:capture3) do |*cmd|
      case cmd.first
      when "unzip"
        write_trace_fixture(cmd[cmd.index("-d") + 1], frames: frames)
        [ "", "", ffmpeg_success ]
      when "ffmpeg"
        cmd_args = cmd
        if cmd_args.any? { |a| a.include?("palettegen") }
          palette_used = true
          pattern = cmd_args[cmd_args.index("-i") + 1]
          ordered_dir = File.dirname(pattern)
          ordered_entries = Dir.children(ordered_dir).sort.filter_map do |entry|
            next unless entry.end_with?(".png")

            File.binread(File.join(ordered_dir, entry))
          end
        else
          File.write(gif_output_path, "GIF89a-fake")
        end
        [ "", "", ffmpeg_success ]
      end
    end
    [ -> { palette_used }, -> { File.exist?(gif_output_path) }, -> { ordered_entries } ]
  end

  def stub_video_to_gif(video_path, gif_output_path)
    File.write(video_path, "fake video data")
    frame_extracted = false
    allow(Open3).to receive(:capture3) do |*cmd|
      next nil unless cmd.first == "ffmpeg"

      cmd_args = cmd
      if cmd_args.any? { |a| a.include?("palettegen") }
        [ "", "", ffmpeg_success ]
      elsif cmd_args.any? { |a| a.include?("paletteuse") }
        File.write(gif_output_path, "GIF89a-fake")
        [ "", "", ffmpeg_success ]
      else
        frame_extracted = true
        [ "", "", ffmpeg_success ]
      end
    end
    [ -> { frame_extracted }, -> { File.exist?(gif_output_path) } ]
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

  def frame_payloads(entries)
    entries.map { |entry| entry.byteslice(8..) }
  end
end
