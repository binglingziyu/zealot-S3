# frozen_string_literal: true

class ApplicationUploader < CarrierWave::Uploader::Base
  storage(Zealot::Storage::S3.enabled? ? Zealot::Storage::S3 : :file)
  cache_storage :file

  def object_attribute
    if model.is_a?(Release)
      mounted_as.to_sym == :icon ? :icon_object_id : :package_object_id
    elsif model.is_a?(DebugFile)
      :stored_object_id
    end
  end

  def bound_object
    id = object_attribute && model[object_attribute]
    StoredObject.find(id) if id
  end

  def selected_profile
    if model.is_a?(Release) && mounted_as.to_sym == :icon && model.package_object
      model.package_object.storage_profile
    else
      model.app.effective_storage_profile
    end
  end

  def remote_storage?
    file.is_a?(Zealot::Storage::S3::File)
  end

  def stored_file_exists?
    return false unless file

    remote_storage? ? file.exists? : File.file?(file.path.to_s)
  end

  def with_local_file(&block)
    if remote_storage?
      file.with_local_file(&block)
    else
      yield file.path
    end
  end

  def signed_download_url(filename:)
    disposition = ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: filename)
    file.url(disposition: disposition)
  end
  after :remove, :delete_empty_upstream_dirs

  def base_store_dir
    'uploads'
  end

  def size
    @size = file&.size
  end

  def checksum
    with_local_file { |path| Digest::MD5.file(path).hexdigest }
  end

  protected

  # Copy from https://github.com/carrierwaveuploader/carrierwave/wiki/how-to:-make-a-fast-lookup-able-storage-directory-structure
  def delete_empty_upstream_dirs
    return if Zealot::Storage::S3.enabled?

    path = ::File.expand_path(store_dir, root)
    Dir.delete(path) # fails if path not empty dir

    path = ::File.expand_path(base_store_dir, root)
    Dir.delete(path) # fails if path not empty dir
  rescue SystemCallError
    true # nothing, the dir is not empty
  end
end
