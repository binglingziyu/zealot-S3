# frozen_string_literal: true

require 'zip'

module Uploads
  class ArchiveGuard
    def self.check!(path)
      return unless File.binread(path, 4).start_with?('PK')
      byte_limit = Integer(ENV.fetch('ZEALOT_PARSER_EXPANDED_BYTES', (32 * 1024**3).to_s))
      count_limit = Integer(ENV.fetch('ZEALOT_PARSER_SCRATCH_ENTRIES', '100000'))
      raise ArgumentError, 'Archive limits must be positive' unless byte_limit.positive? && count_limit.positive?
      Zip::File.open(path) do |archive|
        raise ArgumentError, 'Archive contains too many entries' if archive.size > count_limit
        bytes = 0
        archive.each do |entry|
          name = entry.name.tr('\\', '/')
          if name.start_with?('/') || name.match?(/\A[A-Za-z]:/) || name.include?("\0") || name.split('/').include?('..') || entry.symlink?
            raise ArgumentError, 'Archive contains an unsafe path or symbolic link'
          end
          bytes += entry.size
          raise ArgumentError, 'Archive exceeds the expanded size limit' if bytes > byte_limit
        end
      end
    end
  end
end
