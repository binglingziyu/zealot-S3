# frozen_string_literal: true

module Storage
  # Parsing needs a local file. Enforce the bound as bytes arrive, rather than
  # trusting Content-Length or discovering an oversized object after download.
  class LocalDownload
    class LimitExceeded < StandardError; end
    class SizeMismatch < StandardError; end

    def self.open(client:, bucket:, key:, filename:, expected_size: nil)
      maximum = Integer(ENV.fetch('ZEALOT_PARSER_MAX_FILE_BYTES', (20 * 1024**3).to_s))
      raise ArgumentError, 'ZEALOT_PARSER_MAX_FILE_BYTES must be positive' unless maximum.positive?
      expected = Integer(expected_size) unless expected_size.nil?
      raise ArgumentError, 'Expected size must not be negative' if expected&.negative?
      raise LimitExceeded, 'Object exceeds the parser download limit' if expected && expected > maximum
      limit = expected || maximum

      Tempfile.create(['zealot-object-', File.extname(filename)], Rails.root.join('tmp')) do |file|
        file.binmode
        received = 0
        begin
          client.get_object(bucket: bucket, key: key) do |chunk|
            received += chunk.bytesize
            raise LimitExceeded, 'Object exceeds the parser download limit' if received > limit
            file.write(chunk)
          end
        rescue Aws::S3::Plugins::NonRetryableStreamingError => error
          # The SDK wraps exceptions from streaming consumers. Preserve our
          # actionable size error instead of reporting it as a network failure.
          original = error
          original = original.original_error while original.respond_to?(:original_error)
          raise original if original.is_a?(LimitExceeded)
          raise
        end
        raise SizeMismatch, 'Object size changed' if expected && received != expected
        file.flush
        yield file.path
      end
    end
  end
end
