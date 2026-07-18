# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Screenshots
  # Converts a Playwright trace (or frames/video) into an animated `.gif`
  # suitable for PR comments as an upgrade from static before/after PNGs.
  #
  # Inputs (use exactly one):
  #
  # - `trace_path`: a Playwright `trace.zip`. Screencast frame order is
  #   reconstructed from trace metadata before extracted PNG resources are
  #   stitched into a GIF.
  # - `frames_dir`: a directory of PNG files in the desired order.
  # - `frames`: an explicit list of PNG paths in the order they should appear.
  # - `video_path`: an existing video file (e.g., the `.webm` produced by
  #   `Screenshots::TraceToVideo`) to transcode into a GIF.
  #
  # Conversion is delegated to `ffmpeg` using a two-pass palette pipeline for
  # high-quality output. When ffmpeg is not installed the service raises a
  # descriptive error.
  #
  # @example Convert a trace to an animated GIF
  #   Screenshots::TraceToGif.call(
  #     trace_path: "/tmp/trace.zip",
  #     output_path: "/tmp/demo.gif",
  #     framerate: 8
  #   )
  class TraceToGif
    class ConversionError < StandardError; end
    class FrameSourceMissing < ArgumentError; end

    DEFAULT_FRAMERATE = 8
    DEFAULT_WIDTH = 960
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
    # @param video_path [String, nil] Existing video file (e.g., `.webm`)
    # @param output_path [String] Destination `.gif` file path
    # @param framerate [Integer] Frames per second (default 8)
    # @param width [Integer] Output width in pixels (default 960); height scaled
    #   to preserve aspect ratio
    # @param logger [#info, #warn] Logger for structured diagnostics
    def initialize(trace_path: nil, frames_dir: nil, frames: nil, video_path: nil,
      output_path:, framerate: DEFAULT_FRAMERATE, width: DEFAULT_WIDTH, logger: Rails.logger)
      provided = [ trace_path, frames_dir, frames, video_path ].compact.size
      raise ArgumentError, "exactly one of trace_path, frames_dir, frames, or video_path must be provided" unless provided == 1
      raise ArgumentError, "output_path is required" if output_path.blank?
      raise ArgumentError, "framerate must be positive" unless framerate.to_i.positive?
      raise ArgumentError, "width must be positive" unless width.to_i.positive?

      @trace_path = trace_path
      @frames_dir = frames_dir
      @frames = frames
      @video_path = video_path
      @output_path = output_path
      @framerate = framerate.to_i
      @width = width.to_i
      @logger = logger
    end

    # @return [String] Path to the produced `.gif` file (same as `output_path`)
    def call
      self.class.configured? or
        raise ConversionError, "ffmpeg is not installed; install ffmpeg to convert traces to GIF"

      FileUtils.mkdir_p(File.dirname(@output_path))

      Dir.mktmpdir("trace-to-gif-") do |tmpdir|
        frames_dir = resolve_frames_dir(tmpdir)
        run_ffmpeg(frames_dir)
      end

      @logger&.info(
        message: "screenshots.trace_to_gif.converted",
        output_path: @output_path,
        framerate: @framerate,
        width: @width
      )

      @output_path
    end

    private

    def resolve_frames_dir(tmpdir)
      return extract_trace_frames(tmpdir) if @trace_path
      return materialize_frames_dir(@frames_dir, tmpdir) if @frames_dir
      return materialize_frames(tmpdir) if @frames
      return transcode_video(tmpdir) if @video_path

      raise FrameSourceMissing, "no frame source provided"
    end

    def extract_trace_frames(tmpdir)
      raise ArgumentError, "trace file not found: #{@trace_path}" unless File.exist?(@trace_path)

      extract_dir = File.join(tmpdir, "frames")
      FileUtils.mkdir_p(extract_dir)

      _stdout, stderr, status = Open3.capture3("unzip", "-q", "-o", @trace_path, "-d", extract_dir)
      raise ConversionError, "unzip failed for #{@trace_path}: #{stderr}" unless status.success?

      pngs = TraceFrameSequence.ordered_pngs(extract_dir)

      ordered_dir = File.join(tmpdir, "ordered")
      FileUtils.mkdir_p(ordered_dir)
      pngs.each_with_index do |src, idx|
        FileUtils.cp(src, File.join(ordered_dir, format(DEFAULT_FRAME_PATTERN, idx + 1)))
      end

      ordered_dir
    rescue TraceFrameSequence::Error => e
      raise ConversionError, "trace #{@trace_path} #{e.message}"
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

    def materialize_frames_dir(source_dir, tmpdir)
      raise ArgumentError, "frames_dir not found: #{source_dir}" unless File.directory?(source_dir)

      pngs = Dir.glob(File.join(source_dir, "*.png")).sort
      raise ConversionError, "frames_dir #{source_dir} contains no PNG frames" if pngs.empty?

      ordered_dir = File.join(tmpdir, "ordered")
      FileUtils.mkdir_p(ordered_dir)
      pngs.each_with_index do |src, idx|
        FileUtils.cp(src, File.join(ordered_dir, format(DEFAULT_FRAME_PATTERN, idx + 1)))
      end

      ordered_dir
    end

    def transcode_video(tmpdir)
      raise ArgumentError, "video file not found: #{@video_path}" unless File.exist?(@video_path)

      frames_dir = File.join(tmpdir, "frames")
      FileUtils.mkdir_p(frames_dir)
      pattern = File.join(frames_dir, DEFAULT_FRAME_PATTERN)

      cmd = [
        "ffmpeg",
        "-y",
        "-i", @video_path,
        "-vf", "fps=#{@framerate},scale=#{@width}:-1:flags=lanczos",
        pattern
      ]

      _stdout, stderr, status = Open3.capture3(*cmd)
      raise ConversionError, "ffmpeg frame extraction failed: #{stderr}" unless status.success?

      frames_dir
    end

    def run_ffmpeg(frames_dir)
      pattern = File.join(frames_dir, DEFAULT_FRAME_PATTERN)
      palette = File.join(frames_dir, "palette.png")

      palette_cmd = [
        "ffmpeg",
        "-y",
        "-framerate", @framerate.to_s,
        "-i", pattern,
        "-vf", "scale=#{@width}:-1:flags=lanczos,palettegen=stats_mode=diff",
        palette
      ]

      _stdout, stderr, status = Open3.capture3(*palette_cmd)
      raise ConversionError, "ffmpeg palettegen failed: #{stderr}" unless status.success?

      gif_cmd = [
        "ffmpeg",
        "-y",
        "-framerate", @framerate.to_s,
        "-i", pattern,
        "-i", palette,
        "-lavfi", "scale=#{@width}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5",
        "-loop", "0",
        @output_path
      ]

      _stdout, stderr, status = Open3.capture3(*gif_cmd)
      return if status.success?

      tail = stderr.to_s.lines.last.to_s.strip
      raise ConversionError, "ffmpeg failed (exit #{status.exitstatus}): #{tail}"
    end
  end
end
