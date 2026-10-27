# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require 'find'

module Uploads
  class ParserProcess
    class Failed < StandardError; end
    class Busy < StandardError; end

    def initialize(id)
      @id = id
    end

    def self.cleanup_abandoned(now: Time.current)
      root = Rails.root.join('tmp', 'parser-jobs')
      return unless root.directory?
      root.children.each do |path|
        next unless path.basename.to_s.start_with?('parse-') && !path.symlink? && path.directory? && path.mtime < (now - 2.hours).to_time
        File.open(path.join('.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          FileUtils.remove_entry_secure(path.to_s)
        end
      rescue Errno::ENOENT
        next
      end
    end

    def call
      UploadSession.connection_pool.with_connection do |connection|
        slots = positive('ZEALOT_PARSER_CONCURRENCY', 2)
        slot = (0...slots).find do |number|
          connection.select_value("SELECT pg_try_advisory_lock(#{slot_key(number)})")
        end
        raise Busy, 'Parser workers are busy' unless slot
        begin
          run
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{slot_key(slot)})")
        end
      end
    end

    private

    def slot_key(number)
      Digest::SHA256.hexdigest("parser-slot:#{number}")[0, 15].to_i(16)
    end

    def positive(name, default)
      value = Integer(ENV.fetch(name, default.to_s))
      raise ArgumentError, "#{name} must be positive" unless value.positive?
      value
    end

    def run
      root = Rails.root.join('tmp', 'parser-jobs')
      FileUtils.mkdir_p(root, mode: 0o700)
      Dir.mktmpdir('parse-', root) do |scratch|
        File.open(File.join(scratch, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_SH)
          claim = File.join(scratch, 'claim')
          begin
            supervise(scratch, claim)
          rescue Failed, SystemCallError => error
            ProcessUploadJob.fail_isolated(@id, error.message, claim: File.exist?(claim) ? File.read(claim).to_i : nil)
            Rails.logger.warn("Direct upload #{@id}: #{error.message}")
          end
        end
      end
    end

    def supervise(scratch, claim)
      reaped = false
      seconds = positive('ZEALOT_PARSER_TIMEOUT_SECONDS', 600)
      env = {
        'ZEALOT_PARSER_CHILD' => 'true', 'ZEALOT_PARSER_TMPDIR' => scratch,
        'TMPDIR' => scratch, 'MAGICK_TEMPORARY_PATH' => scratch,
        'ZEALOT_PARSER_PARENT_PID' => Process.pid.to_s,
        'ZEALOT_PARSER_TIMEOUT_SECONDS' => seconds.to_s
      }
      pid = Process.spawn(env, *command(claim),
        chdir: Rails.root.to_s, pgroup: true, in: File::NULL,
        rlimit_core: 0,
        rlimit_cpu: positive('ZEALOT_PARSER_CPU_SECONDS', 300),
        rlimit_as: positive('ZEALOT_PARSER_MEMORY_BYTES', 4 * 1024**3),
        rlimit_fsize: positive('ZEALOT_PARSER_MAX_FILE_BYTES', 20 * 1024**3))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      disk_limit = positive('ZEALOT_PARSER_SCRATCH_BYTES', 64 * 1024**3)
      entries_limit = positive('ZEALOT_PARSER_SCRATCH_ENTRIES', 100_000)
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        if result
          reaped = true
          raise Failed, "Parser exited unsuccessfully (#{result.last})" unless result.last.success?
          break
        end
        raise Failed, 'Parser exceeded its time limit' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        entries = 0
        bytes = 0
        Find.find(scratch) do |path|
          entries += 1
          raise Failed, 'Parser exceeded its scratch entry limit' if entries > entries_limit
          stat = File.lstat(path)
          bytes += stat.size if stat.file?
          raise Failed, 'Parser exceeded its scratch space limit' if bytes > disk_limit
        rescue Errno::ENOENT
          next
        end
        sleep 0.25
      end
    ensure
      if pid
        # Kill descendants too, including converters that outlive their Ruby parent.
        begin
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH
        end
        Process.waitpid(pid) unless reaped
      end
    end

    def command(claim)
      [RbConfig.ruby, Rails.root.join('bin/parse_upload').to_s, @id.to_s, claim]
    end
  end
end
