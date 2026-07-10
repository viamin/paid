# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Screenshots
  # Converts a Playwright trace (or a sequence of PNG frames) into a `.webm`
  # video suitable for documentation, onboarding, and feature showcase reels.
  #
  # Inputs (use exactly one):
  #
  # - `trace_path`: a Playwright `trace.zip` produced by `context.tracing.stop`.
  #   The embedded `*.png` screenshots are extracted, ordered by their sequence
  #   number, and stitched into a video.
  # - `frames_dir`: a directory of PNG files already ordered (lexicographic
  #   order). Useful when the trace frames have been pre-extracted.
  # - `frames`: an explicit list of PNG paths in the order they should appear.
  #
  # Conversion is delegated to `ffmpeg`. When ffmpeg is not installed the
  # service raises a descriptive error — the agent/container must install it.
  #
  # @example Convert a trace to video
  #   Screenshots::TraceToVideo.call(
  #     trace_path: "/tmp/trace.zip",
  #     output_path: "/tmp/demo.webm",
  #     framerate: 24
  #   )
  class TraceToVideo
    class ConversionError < StandardError; end
    class FrameSourceMissing < ArgumentError; end

    DEFAULT_FRAMERATE = 12
    DEFAULT_FRAME_PATTERN = "%05d.png"

    def self.call(...)
      new(...).call
    end

    # @return [Boolean] true when the `ffmpeg` binary is available on PATH
    def self.configured?
      _stdout, _stderr, status = Open3.capture3("ffmpeg", "-version")
      status.success?
    rescue Errno::ENOENT
      false
    end

    # @param trace_path [String, nil] Path to a Playwright trace `.zip`
    # @param frames_dir [String, nil] Directory of ordered PNG frames
    # @param frames [Array<String>, nil] Explicit list of PNG frame paths
    # @param output_path [String] Destination `.webm` file path
    # @param framerate [Integer] Frames per second (default 12)
    # @param logger [#info, #warn] Logger for structured diagnostics
    def initialize(trace_path: nil, frames_dir: nil, frames: nil, output_path:, framerate: DEFAULT_FRAMERATE, logger: Rails.logger)
      if [ trace_path, frames_dir, frames ].compact.size != 1
        raise ArgumentError, "exactly one of trace_path, frames_dir, or frames must be provided"
      end
      raise ArgumentError, "output_path is required" if output_path.blank?
      raise ArgumentError, "framerate must be positive" unless framerate.to_i.positive?

      @trace_path = trace_path
      @frames_dir = frames_dir
      @frames = frames
      @output_path = output_path
      @framerate = framerate.to_i
      @logger = logger
    end

    # @return [String] Path to the produced `.webm` file (same as `output_path`)
    def call
      self.class.configured? or
        raise ConversionError, "ffmpeg is not installed; install ffmpeg to convert traces to video"

      FileUtils.mkdir_p(File.dirname(@output_path))

      Dir.mktmpdir("trace-to-video-") do |tmpdir|
        frames_dir = resolve_frames_dir(tmpdir)
        run_ffmpeg(frames_dir)
      end

      @logger&.info(
        message: "screenshots.trace_to_video.converted",
        output_path: @output_path,
        framerate: @framerate,
        frame_count: frame_count
      )

      @output_path
    end

    private

    def resolve_frames_dir(tmpdir)
      return extract_trace_frames(tmpdir) if @trace_path
      return @frames_dir if @frames_dir
      return materialize_frames(tmpdir) if @frames

      raise FrameSourceMissing, "no frame source provided"
    end

    def extract_trace_frames(tmpdir)
      raise ArgumentError, "trace file not found: #{@trace_path}" unless File.exist?(@trace_path)

      extract_dir = File.join(tmpdir, "frames")
      FileUtils.mkdir_p(extract_dir)

      _stdout, stderr, status = Open3.capture3("unzip", "-q", "-o", @trace_path, "-d", extract_dir)
      raise ConversionError, "unzip failed for #{@trace_path}: #{stderr}" unless status.success?

      pngs = Dir.glob(File.join(extract_dir, "**", "*.png")).sort
      raise ConversionError, "trace #{@trace_path} contains no PNG frames" if pngs.empty?

      ordered_dir = File.join(tmpdir, "ordered")
      FileUtils.mkdir_p(ordered_dir)
      pngs.each_with_index do |src, idx|
        FileUtils.cp(src, File.join(ordered_dir, format(DEFAULT_FRAME_PATTERN, idx + 1)))
      end

      ordered_dir
    end

    def materialize_frames(tmpdir)
      ordered_dir = File.join(tmpdir, "ordered")
      FileUtils.mkdir_p(ordered_dir)

      @frames.each_with_index do |src, idx|
        raise ArgumentError, "frame not found: #{src}" unless File.exist?(src)
        FileUtils.cp(src, File.join(ordered_dir, format(DEFAULT_FRAME_PATTERN, idx + 1)))
      end

      ordered_dir
    end

    def run_ffmpeg(frames_dir)
      pattern = File.join(frames_dir, DEFAULT_FRAME_PATTERN)
      cmd = [
        "ffmpeg",
        "-y",
        "-framerate", @framerate.to_s,
        "-i", pattern,
        "-c:v", "libvpx-vp9",
        "-b:v", "1M",
        "-pix_fmt", "yuv420p",
        @output_path
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      return if status.success?

      tail = stderr.to_s.lines.last.to_s.strip
      raise ConversionError, "ffmpeg failed (exit #{status.exitstatus}): #{tail}"
    end

    def frame_count
      if @frames
        @frames.size
      elsif @frames_dir && File.directory?(@frames_dir)
        Dir.glob(File.join(@frames_dir, "*.png")).size
      else
        0
      end
    end
  end
end
