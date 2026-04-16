# frozen_string_literal: true

# Helpers for silencing stdout/stderr across entire example groups.
# RSpec's built-in `output` matcher is designed for assertions in examples
# (`expect { ... }.to output(...).to_stdout`); the RSpec/ExpectInHook and
# RSpec/ExpectOutput cops rightly discourage it in hooks. This module exists
# so specs that wrap noisy code (e.g. rake tasks that `puts` progress lines)
# can silence streams from an `around` hook without tripping either cop.
#
#   around { |example| SilenceStreams.call(:stdout, :stderr) { example.run } }
module SilenceStreams
  module_function

  # Redirects the given streams (any of :stdout, :stderr) to fresh StringIOs
  # for the duration of the block, then restores the originals.
  def call(*streams)
    originals = streams.to_h { |s| [ s, stream_get(s) ] }
    streams.each { |s| stream_set(s, StringIO.new) }
    yield
  ensure
    originals&.each { |s, original| stream_set(s, original) }
  end

  def stream_get(name)
    case name
    when :stdout then $stdout
    when :stderr then $stderr
    else raise ArgumentError, "unknown stream #{name.inspect}"
    end
  end

  def stream_set(name, io)
    case name
    when :stdout then $stdout = io
    when :stderr then $stderr = io
    else raise ArgumentError, "unknown stream #{name.inspect}"
    end
  end
end
