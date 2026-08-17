# frozen_string_literal: true

require "tmpdir"

module Screenshots
  class TraceArtifactExporter
    def self.call(...)
      new(...).call
    end

    def initialize(storage:, org:, repo:, pr_number:, commit_sha:, route_name:,
      trace_path: nil, frames_dir: nil, frames: nil, logger: Rails.logger,
      log_message:, log_context: {})
      @storage = storage
      @org = org
      @repo = repo
      @pr_number = pr_number
      @commit_sha = commit_sha
      @route_name = route_name
      @trace_path = trace_path
      @frames_dir = frames_dir
      @frames = frames
      @logger = logger
      @log_message = log_message
      @log_context = log_context
    end

    def call
      return {} unless exportable_source?

      Dir.mktmpdir("screenshots-trace-export-") do |tmpdir|
        video_path = File.join(tmpdir, "#{@route_name}.webm")
        gif_path = File.join(tmpdir, "#{@route_name}.gif")

        export_video(video_path).merge(export_gif(gif_path))
      end
    end

    private

    def export_video(video_path)
      Screenshots::TraceToVideo.call(**conversion_source, output_path: video_path)
      key = artifact_key(".webm")
      url = upload_artifact(video_path)

      {
        video_url: url,
        video_filename: "#{@route_name}.webm",
        video_artifact: {
          "kind" => "trace_video",
          "content_type" => Screenshots::Storage::WEBM_CONTENT_TYPE,
          "locator" => { "key" => key, "url" => url },
          "metadata" => {
            "route_name" => @route_name,
            "filename" => "#{@route_name}.webm"
          }
        }
      }
    rescue Screenshots::TraceToVideo::ConversionError => e
      log_failure(e)
      {}
    end

    def export_gif(gif_path)
      Screenshots::TraceToGif.call(**conversion_source, output_path: gif_path)
      key = artifact_key(".gif")
      url = upload_artifact(gif_path)

      {
        gif_url: url,
        gif_artifact: {
          "kind" => "trace_gif",
          "content_type" => Screenshots::Storage::GIF_CONTENT_TYPE,
          "locator" => { "key" => key, "url" => url },
          "metadata" => {
            "route_name" => @route_name,
            "filename" => "#{@route_name}.gif"
          }
        }
      }
    rescue Screenshots::TraceToGif::ConversionError => e
      log_failure(e)
      {}
    end

    def log_failure(error)
      @logger.warn(
        {
          message: @log_message,
          route_name: @route_name,
          error: error.message
        }.merge(@log_context)
      )
    end

    def exportable_source?
      return true if @trace_path.present? || @frames_dir.present?

      Array(@frames).many?
    end

    def conversion_source
      return { trace_path: @trace_path } if @trace_path.present?
      return { frames_dir: @frames_dir } if @frames_dir.present?

      { frames: Array(@frames) }
    end

    def upload_artifact(file_path)
      @storage.upload_artifact(
        file_path: file_path,
        org: @org,
        repo: @repo,
        pr_number: @pr_number,
        commit_sha: @commit_sha,
        route_name: @route_name
      )
    end

    def artifact_key(extension)
      @storage.artifact_key(
        org: @org,
        repo: @repo,
        pr_number: @pr_number,
        commit_sha: @commit_sha,
        route_name: @route_name,
        extension: extension
      )
    end
  end
end
