# frozen_string_literal: true

require 'pathname'

class Backup < ApplicationRecord
  belongs_to :storage_profile, optional: true
  include BackupFile

  scope :enabled_jobs, -> { where(enabled: true) }

  validates :key, uniqueness: true, on: :create
  validates :key, :schedule, presence: true
  validate :correct_schedule
  validate :fixed_backup_location

  before_save :strip_enabled_apps
  after_save :update_worker_scheduler

  before_destroy :remove_storage

  def apps
    App.where(id: enabled_apps)
  end

  def perform_job(user_id)
    BackupJob.perform_later(id, user_id)
  end

  def find_file(filename)
    return remote_service.files.find { |file| file.basename == filename.to_s } if remote_database?
    file = Dir.glob(File.join(backup_path, filename)).first
    return unless file

    Pathname.new(file)
  end

  def backup_files
    return remote_service.files if remote_database?
    Dir.glob(File.join(backup_path, '*.tar')).each_with_object([]) do |file, obj|
      backup_file = BackupFile.new(file)
      next unless backup_file.completed?

      obj << backup_file
    end.sort_by(&:ctime).reverse!
  end

  def performing_jobs
    jobs = GoodJob::Job.where(job_class: 'BackupJob')
      .where("serialized_params#>>'{arguments,0}' = ?", id.to_s)
      .order(created_at: :desc)

    jobs.each_with_object([]) do |good_job, obj|
      next if good_job.succeeded?

      activejob_status = ActiveJob::Status.get(good_job.id)
      job = PerformingJob.new(good_job, activejob_status)
      obj << job
    end
  end

  def destroy_directory(name)
    return remote_service.delete(name) if remote_database?
    Dir.glob(File.join(backup_path, "#{name}*")).each do |file|
      FileUtils.rm_rf(file)
    end
  end

  def remove_background_jobs(job_id = nil)
    status = ActiveJob::Status.get(job_id)
    if status.present?
      backup_file = status[:file]
      destroy_directory(backup_file) unless remote_database?
      status.delete
    end

    GoodJob::Job.destroy(job_id)
  end

  def backup_path
    @backup_path ||= Rails.root.join(Setting.backup[:path], key)
  end

  def remote_database?
    Zealot::Storage::S3.enabled? && StorageProfile.exists?
  end

  def remote_service
    Backups::RemoteDatabase.new(self)
  end

  def schedule_job
    data = []
    data << 'database' if enabled_database
    data << "#{enabled_apps.size} apps" if enabled_apps

    {
      description: "Backup zealot #{data.join(' | ')} data",
      cron: Fugit.parse(schedule).to_cron_s,
      class:'BackupJob',
      args: [ id ]
    }
  end

  def schedule_key
    @scheduler_key ||= "zealot_backup_#{key}".to_sym
  end

  private

  def fixed_backup_location
    return unless persisted? && will_save_change_to_storage_profile_id? && storage_profile_id_in_database
    prefix = StorageProfile.find(storage_profile_id_in_database).key("database-backups/#{id}/")
    if StoredObject.where(storage_profile_id: storage_profile_id_in_database, kind: 'backup')
      .where('left(key, ?) = ?', prefix.length, prefix).exists?
      errors.add(:storage_profile, 'already contains backups; create a new backup schedule to use another location')
    end
  end

  def correct_schedule
    parser = Fugit.do_parse(self.schedule)
    klass = parser.class

    raise ArgumentError, "Not match cron expression: #{klass}" unless klass == Fugit::Cron
  rescue ArgumentError => e
    errors.add(:schedule, :invalid)
  end

  def strip_enabled_apps
    enabled_apps.compact!
  end

  def remove_storage
    FileUtils.rm_rf(backup_path)
  end

  def update_worker_scheduler
    # FIXME: This class exists, must rename new one, may be SchedulerExt?
    # code: lib/good_lib/good_job_ext.rb
    #
    # scheduler = GoodJob::Scheduler.new
    # has_cron = scheduler.key?(schedule_key)
    # return if has_cron && enabled

    # if enabled
    #   scheduler.add(schedule_key, schedule_job) unless has_cron
    # else
    #   scheduler.remove(schedule_key) if has_cron
    # end

    configuration = GoodJob.configuration
    cron = configuration.cron
    has_cron = cron.key?(schedule_key)
    return if has_cron && enabled

    if enabled && !has_cron
      cron[schedule_key] = schedule_job
    elsif !enabled && has_cron
      cron.delete(schedule_key)
    end

    # NOTE: no needs
    # capsule = GoodJob::Capsule.new(configuration: configuration)
    # GoodJob.capsule = capsule
    # capsule.restart
  end
end
