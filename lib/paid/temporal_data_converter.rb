# frozen_string_literal: true

require "temporalio/converters/data_converter"

module Paid
  # @spec TEMPORAL-ORCHESTRATION-011
  class TemporalDataConverter < Temporalio::Converters::DataConverter
    class JSONPlain < Temporalio::Converters::PayloadConverter::JSONPlain
      def to_payload(value, **)
        data = with_workflow_scheduler_disabled { JSON.generate(value, **generate_options).b }
        Temporalio::Api::Common::V1::Payload.new(metadata: { "encoding" => encoding }, data:)
      end

      def from_payload(payload, **)
        with_workflow_scheduler_disabled { JSON.parse(payload.data, **parse_options) }
      end

      private

      attr_reader :generate_options, :parse_options

      def with_workflow_scheduler_disabled(&)
        return yield unless Temporalio::Workflow.in_workflow?

        Temporalio::Workflow::Unsafe.durable_scheduler_disabled(&)
      end
    end

    def initialize
      payload_converter = Temporalio::Converters::PayloadConverter::Composite.new(
        Temporalio::Converters::PayloadConverter::BinaryNull.new,
        Temporalio::Converters::PayloadConverter::BinaryPlain.new,
        Temporalio::Converters::PayloadConverter::JSONProtobuf.new,
        Temporalio::Converters::PayloadConverter::BinaryProtobuf.new,
        JSONPlain.new(parse_options: {}, generate_options: {})
      )
      super(payload_converter:)
    end
  end
end
