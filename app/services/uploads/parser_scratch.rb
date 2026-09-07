# frozen_string_literal: true

module Uploads
  # AppInfo's archive helper hardcodes /tmp; TMPDIR alone does not redirect it.
  # Prepend only inside the disposable parser process.
  module ParserScratch
    def unarchive(file, prefix:, dest_path: nil, &block)
      super(file, prefix: prefix, dest_path: ENV.fetch('ZEALOT_PARSER_TMPDIR'), &block)
    end

    def tempdir(file, prefix:, system: false)
      path = Dir.mktmpdir("appinfo-#{prefix}-", ENV.fetch('ZEALOT_PARSER_TMPDIR'))
      File.join(path, File.basename(file))
    end
  end
end
