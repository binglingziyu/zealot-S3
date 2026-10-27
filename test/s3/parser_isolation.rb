require_relative 'multipart'
require 'minitest/mock'

class ParserIsolationTest < MultipartTest
  def setup
    super
    @parser_env = ENV.to_h.select { |key, _| key.start_with?('ZEALOT_PARSER_') }
  end

  def teardown
    ENV.keys.grep(/^ZEALOT_PARSER_/).each { |key| ENV.delete(key) }
    @parser_env.each { |key, value| ENV[key] = value }
    super
  end

  def test_isolated_timeout_is_retryable_without_losing_the_object
    bytes = 'retryable isolated linux package'
    session = initiate(bytes)
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, bytes).code
    service.complete
    ENV['ZEALOT_PARSER_TIMEOUT_SECONDS'] = '1'
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'failed', session.reload.state
    assert_equal 1, session.attempts
    assert_nil session.release_id
    assert_equal bytes, @profile.client.get_object(bucket: @profile.bucket, key: session.stored_object.key).body.read
    ENV['ZEALOT_PARSER_TIMEOUT_SECONDS'] = '600'
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'ready', session.reload.state, session.error_message
    assert_equal 2, session.attempts
    assert_equal 1, @channel.releases.count
    assert_empty Dir[Rails.root.join("tmp/parser-jobs/parse-*-#{Process.pid}-*").to_s]
  end

  def test_isolated_failure_cannot_replace_a_newer_attempt_or_ready_result
    session = initiate('never download')
    session.update!(state: 'parsing', attempts: 3)
    ProcessUploadJob.fail_isolated(session.id, 'old timeout', claim: 2)
    assert_equal 'parsing', session.reload.state
    ProcessUploadJob.fail_isolated(session.id, 'current timeout', claim: 3)
    assert_equal 'failed', session.reload.state
    session.update!(state: 'ready')
    ProcessUploadJob.fail_isolated(session.id, 'late timeout', claim: 3)
    assert_equal 'ready', session.reload.state
  end

  def test_isolated_concurrency_slot_is_shared_across_database_connections
    ENV['ZEALOT_PARSER_CONCURRENCY'] = '1'
    key = Digest::SHA256.hexdigest('parser-slot:0')[0, 15].to_i(16)
    UploadSession.connection_pool.with_connection do |connection|
      connection.execute("SELECT pg_advisory_lock(#{key})")
      begin
        result = Thread.new do
          Uploads::ParserProcess.new('unused').call
          :unexpected
        rescue Uploads::ParserProcess::Busy
          :busy
        end.value
        assert_equal :busy, result
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{key})")
      end
    end
  end

  def test_isolated_cpu_limit_terminates_a_runaway_child
    ENV['ZEALOT_PARSER_CPU_SECONDS'] = '1'
    ENV['ZEALOT_PARSER_TIMEOUT_SECONDS'] = '15'
    assert_supervisor_failure('loop {}', /exited unsuccessfully/)
  end

  def test_isolated_scratch_limit_terminates_a_writing_child
    ENV['ZEALOT_PARSER_SCRATCH_BYTES'] = '4096'
    assert_supervisor_failure("File.binwrite(File.join(ENV.fetch('TMPDIR'), 'large'), 'x' * 8192); sleep 15", /scratch space limit/)
  end

  def test_isolated_memory_limit_terminates_an_allocating_child
    ENV['ZEALOT_PARSER_MEMORY_BYTES'] = (128 * 1024**2).to_s
    ENV['ZEALOT_PARSER_TIMEOUT_SECONDS'] = '15'
    assert_supervisor_failure("values = []; loop { values << 'x' * 10_000_000 }", /exited unsuccessfully/)
  end

  def test_isolated_kernel_file_limit_stops_a_large_write
    ENV['ZEALOT_PARSER_MAX_FILE_BYTES'] = '4096'
    assert_supervisor_failure("File.binwrite(File.join(ENV.fetch('TMPDIR'), 'large'), 'x' * 8192)", /exited unsuccessfully/)
  end

  def test_isolated_archive_preflight_rejects_paths_and_expansion_limits
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'archive.zip')
      Zip::OutputStream.open(path) { |zip| zip.put_next_entry('../outside'); zip.write('x') }
      assert_raises(ArgumentError) { Uploads::ArchiveGuard.check!(path) }
      File.delete(path)
      Zip::OutputStream.open(path) { |zip| zip.put_next_entry('safe'); zip.write('x' * 8192) }
      ENV['ZEALOT_PARSER_EXPANDED_BYTES'] = '4096'
      error = assert_raises(ArgumentError) { Uploads::ArchiveGuard.check!(path) }
      assert_match(/expanded size limit/, error.message)
    end
  end

  def test_isolated_abandoned_scratch_cleanup_preserves_active_directories
    root = Rails.root.join('tmp', 'parser-jobs')
    FileUtils.mkdir_p(root)
    path = Dir.mktmpdir('parse-cleanup-', root)
    begin
      File.open(File.join(path, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_SH)
        File.utime(3.hours.ago.to_time, 3.hours.ago.to_time, path)
        Uploads::ParserProcess.cleanup_abandoned
        assert File.directory?(path)
      end
      Uploads::ParserProcess.cleanup_abandoned
      refute File.exist?(path)
    ensure
      FileUtils.remove_entry_secure(path) if File.exist?(path)
    end
  end

  private

  def assert_supervisor_failure(code, pattern)
    process = Uploads::ParserProcess.new('unused')
    Dir.mktmpdir do |scratch|
      process.stub(:command, [RbConfig.ruby, '-e', code]) do
        error = assert_raises(Uploads::ParserProcess::Failed) { process.send(:supervise, scratch, File.join(scratch, 'claim')) }
        assert_match pattern, error.message
      end
    end
  end
end
