# frozen_string_literal: true

# Copyright (c) 2011-present GitLab B.V.

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'open3'

module Zealot::Backup
  class Uploads
    include Zealot::Backup::Helper

    class Error < StandardError; end

    def self.dump(manager, app_ids:)
      new(manager.tmpdir, logger: manager.logger).dump(app_ids: app_ids)
    end

    # def self.dump(path: nil, logger: nil, app_ids: nil)
    #   new(path, logger, app_ids).dump
    # end

    def self.restore
      new.restore
    end

    FILENAME = 'uploads.tar.gz'

    attr_reader :path, :logger

    def initialize(path = nil, logger: Rails.logger)
      @path = path
      @logger = logger
    end

    def dump(app_ids: nil)
      if Zealot::Storage::S3.enabled? && !@s3_staging
        return Dir.mktmpdir('zealot-s3-backup') do |directory|
          @s3_staging = directory
          Zealot::Storage::Transfer.export_to(directory, app_ids: app_ids.is_a?(Array) ? app_ids : nil)
          dump(app_ids: app_ids)
        ensure
          @s3_staging = nil
        end
      end
      app_ids = nil if app_ids == :all
      FileUtils.rm_f(backup_tarball)

      logger.debug "Dumping uploads data ... #{uploads_path}"
      apps_path = apps_path(app_ids)
      if !app_ids.nil? && !apps_path
        logger.error "App(s) path was not exist, backup abort."
        return
      end

      apps_path = ['.'] if app_ids.nil?
      logger.debug [archive_tar_cmd(apps_path), gzip_cmd].join(" ")
      logger.debug apps_path
      run_pipeline!([archive_tar_cmd(apps_path), gzip_cmd], out: [backup_tarball, 'w', 0600])
    end

    def restore
      if Zealot::Storage::S3.enabled? && !@s3_staging
        return Dir.mktmpdir('zealot-s3-restore') do |directory|
          @s3_staging = directory
          restore
          Zealot::Storage::Transfer.import_from(directory)
        ensure
          @s3_staging = nil
        end
      end
      logger.debug "Restoring uploads data ... "

      backup_existing_uploads_dir
      FileUtils.mkdir_p(uploads_path)
      run_pipeline!([%w(gzip -cd), %W(#{tar} -C #{uploads_path} -xf -)], in: backup_tarball)
    end

    private

    def apps_path(app_ids)
      return unless app_ids.is_a?(Array) && app_ids.any?

      app_ids.flat_map do |id|
        %w[apps debug_files].filter_map do |kind|
          relative = File.join(kind, "a#{Integer(id)}")
          relative if Dir.exist?(File.join(uploads_path, relative))
        end
      end.presence
    end

    def archive_tar_cmd(apps_path)
      command = %W(#{tar} --exclude=lost+found --exclude=.DS_Store -C #{uploads_path} -cf -)
      command.concat(apps_path)
      command
    end

    def backup_existing_uploads_dir
      timestamped_files_path = File.join(backup_path, "tmp", "uploads.old.#{Time.now.to_i}")
      if File.exist?(uploads_path)
        # Move all files in the existing repos directory except . and .. to
        # uploads.old.<timestamp> directory
        FileUtils.mkdir_p(timestamped_files_path, mode: 0700)
        files = Dir.glob(File.join(uploads_path, "*"),
          File::FNM_DOTMATCH) - [File.join(uploads_path, "."), File.join(uploads_path, "..")]

        begin
          FileUtils.mv(files, timestamped_files_path)
        rescue Errno::EACCES
          access_denied_error(uploads_path)
        rescue Errno::EBUSY
          resource_busy_error(uploads_path)
        end
      end
    end

    def run_pipeline!(cmd_list, options = {})
      err_r, err_w = IO.pipe
      options[:err] = err_w

      status = Open3.pipeline(*cmd_list, options)
      err_w.close
      return true if status.compact.all?(&:success?)

      regex = /^g?tar: \.: Cannot mkdir: No such file or directory$/
      error = err_r.read

      raise Zealot::Backup::UploadsError, "Backup failed: #{error}" unless error =~ regex
    end

    def uploads_path
      return @s3_staging if @s3_staging

      @uploads_path ||= Rails.root.join('public', 'uploads')
    end

    def backup_tarball
      @backup_tarball ||= File.join(backup_path, FILENAME)
    end

    def backup_path
      @backup_path ||= path
    end
  end
end
