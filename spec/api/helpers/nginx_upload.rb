# Copyright (c) 2009-2012 VMware, Inc.

require "rack/test"
require "tmpdir"

class NginxUpload
  def initialize(app)
    @app = app
  end

  def call(env)
    tmpdir = nil
    if multipart?(env)
      form_hash = Rack::Multipart::Parser.new(env.dup).parse
      tmpdir = Dir.mktmpdir("ngx.uploads")
      offload_files!(form_hash, tmpdir)
      offload_staging_uploads!(form_hash, tmpdir)
      data = Rack::Multipart::Generator.new(form_hash).dump
      raise ArgumentError unless data
      env["rack.input"] = StringIO.new(data)
      env["CONTENT_LENGTH"] = data.size.to_s
      env["CONTENT_TYPE"] = "multipart/form-data; boundary=#{Rack::Utils::Multipart::MULTIPART_BOUNDARY}"
    end
    @app.call(env)
  ensure
    FileUtils.remove_entry_secure(tmpdir) if tmpdir
  end

  private

  def multipart?(env)
    return false unless ["PUT", "POST"].include?(env["REQUEST_METHOD"])
    env["CONTENT_TYPE"].downcase.start_with?("multipart/form-data; boundary")
  end

  # @param [Hash] form_hash an env hash containing multipart file fields
  # @return [Hash] the same hash, with file fields replaced by names to files in +tmpdir+
  def offload_files!(form_hash, tmpdir)
    file_keys = form_hash.keys.select do |k|
      next unless k.is_a?(String)
      form_hash[k].is_a?(Hash) && form_hash[k][:tempfile]
    end
    file_keys.each do |k|
      replace_file_with_path(form_hash, k, tmpdir, :include_name => true)
    end
  end

  # similar to +offload_files!+, but only replaces upload[droplet] to droplet_path
  def offload_staging_uploads!(form_hash, tmpdir)
    upload_hash = form_hash.delete("upload")
    return unless upload_hash

    %w[droplet artifact_cache].each do |field_name|
      replace_file_with_path(upload_hash, field_name, tmpdir)
    end

    form_hash.merge!(upload_hash)
  end

  # @param [Hash] form_hash an env hash containing multipart file fields
  # @return [Hash] same hash, with +form_hash[key]+ replaced by name to file in +tmpdir+
  def replace_file_with_path(form_hash, key, tmpdir, options={})
    value = form_hash.delete(key)
    return unless value

    FileUtils.copy(value[:tempfile].path, tmpdir)
    form_hash.merge!(
      "#{key}_path" => File.join(tmpdir, File.basename(value[:tempfile].path)),
      # keeps the uploaded file to trick the multipart encoder, but
      # obfuscates the form field name so we're not likely gonna use it
      ("%06x" % rand(0x1000000)) => Rack::Multipart::UploadedFile.new(value[:tempfile].path),
    )
    form_hash["#{key}_name"] = value[:filename] if options[:include_name]
    value[:tempfile].unlink
  end
end
