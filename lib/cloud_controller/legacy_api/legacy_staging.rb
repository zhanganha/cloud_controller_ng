# Copyright (c) 2009-2012 VMware, Inc.

# All the storing and deleting of droplets was pushed into this class as it is
# a mix of legacy cc and fog related work.  This is because this class is
# responsible for handing out the urls to the droplets, which now gets
# delegated to fog. There is also substantial overlap in code and functionality
# with AppPackage.
#
# As part of the refactor to use the Fog gem, this ended up being done by
# dropping Fog in place directly.  However, now that there is more going on at
# the storage layer than FileUtils.mv, this should get refactored.

module VCAP::CloudController
  class LegacyStaging < LegacyApiBase
    include VCAP::CloudController::Errors

    # Endpoint does its own (non-standard) auth
    allow_unauthenticated_access

    APP_PATH = "/staging/apps"
    DROPLET_PATH = "/staging/droplets"

    class DropletUploadHandle
      attr_accessor :id, :droplet_upload_path, :artifact_cache_upload_path

      def initialize(id)
        @id = id
      end

      def set_path(key, path)
        send("#{key}_upload_path=", path)
      end
    end

    class << self
      def configure(config)
        @config = config

        opts = config[:droplets]
        @droplet_directory_key = opts[:droplet_directory_key] || "cc-droplets"
        @artifact_cache_directory_key = opts[:artifact_cache_directory_key] || "cc-artifact-caches"
        @connection_config = opts[:fog_connection]
        clear_memoized_directories
      end

      def app_uri(id)
        if AppPackage.local?
          staging_uri("#{APP_PATH}/#{id}")
        else
          AppPackage.package_uri(id)
        end
      end

      def artifact_cache_uri(id)
        staging_uri("/staging/artifact-cache/#{id}")
      end

      def droplet_upload_uri(id)
        staging_uri("/staging/droplets/#{id}")
      end

      def droplet_download_uri(id)
        if local?
          staging_uri("/staged_droplets/#{id}")
        else
          file_uri(id, "droplet")
        end
      end

      def create_handle(id)
        handle = DropletUploadHandle.new(id)
        mutex.synchronize do
          if upload_handles[id]
            raise Errors::StagingError.new("staging already in progress for #{id}")
          end
          upload_handles[handle.id] = handle
        end
        handle
      end

      def destroy_handle(handle)
        return unless handle
        mutex.synchronize do
          [handle.droplet_upload_path, handle.artifact_cache_upload_path].each do |path|
            File.delete(path) if path && File.exists?(path)
          end
          upload_handles.delete(handle.id)
        end
      end

      def lookup_handle(id)
        mutex.synchronize do
          return upload_handles[id]
        end
      end

      def store_droplet(guid, path)
        store_file(guid, path, "droplet")
      end

      def store_artifact_cache(guid, path)
        store_file(guid, path, "artifact_cache")
      end

      def delete_droplet(guid)
        key = key_from_guid(guid)
        droplet_dir.files.destroy(key)
      end

      def droplet_exists?(guid)
        file_exists?(guid, "droplet")
      end

      def artifact_cache_exists?(guid)
        file_exists?(guid, "artifact_cache")
      end

      def local?
        @connection_config[:provider].downcase == "local"
      end

      def file_uri(guid, type)
        key = key_from_guid(guid)
        f = storage_dir(type).files.head(key)
        return nil unless f

        # unfortunately fog doesn't have a unified interface for non-public urls
        if local?
          f.public_url
        else
          f.url(Time.now + 3600)
        end
      end

      def local_path(id, type)
        raise ArgumentError unless local?
        key = key_from_guid(id)
        f = storage_dir(type).files.head(key)
        return nil unless f
        # Yes, this is bad.  But, we really need a handle to the actual path in
        # order to serve the file using send_file since send_file only takes a
        # path as an argument
        f.send(:path)
      end

      private

      def file_exists?(app_guid, type)
        key = key_from_guid(app_guid)
        !storage_dir(type).files.head(key).nil?
      end

      def storage_dir(type)
        if type == 'droplet'
          droplet_dir
        else
          artifact_cache_dir
        end
      end

      def store_file(guid, path, type)
        File.open(path) do |file|
          storage_dir(type).files.create(
            :key => key_from_guid(guid),
            :body => file,
            :public => local?
          )
        end
      end

      def clear_memoized_directories
        @directory = nil
        @artifact_cache_dir = nil
      end

      def staging_uri(path)
        URI::HTTP.build(
          :host     => @config[:bind_address],
          :port     => @config[:port],
          :userinfo => [@config[:staging][:auth][:user], @config[:staging][:auth][:password]],
          :path     => path
        ).to_s
      end

      def upload_handles
        @upload_handles ||= {}
      end

      MUTEX = Mutex.new
      def mutex
        MUTEX
      end

      def logger
        @logger ||= Steno.logger("cc.legacy_staging")
      end

      def connection
        opts = @connection_config
        opts = opts.merge(:endpoint => "") if local?
        Fog::Storage.new(opts)
      end

      def droplet_dir
        @directory ||= connection.directories.create(
          :key => @droplet_directory_key,
          :public => false,
        )
      end

      def artifact_cache_dir
        @artifact_cache_dir ||= connection.directories.create(
          :key => @artifact_cache_directory_key,
          :public => false,
        )
      end

      def key_from_guid(guid)
        guid = guid.to_s.downcase
        File.join(guid[0..1], guid[2..3], guid)
      end
    end

    # Handles an app download from a stager
    def download_app(id)
      raise InvalidRequest unless AppPackage.local?

      app = Models::App.find(:guid => id)
      raise AppNotFound.new(id) if app.nil?

      package_path = AppPackage.package_local_path(id)
      logger.debug "id: #{id} package_path: #{package_path}"

      unless package_path
        logger.error "could not find package for #{id}"
        raise AppPackageNotFound.new(id)
      end

      if config[:nginx][:use_nginx]
        url = AppPackage.package_uri(id)
        logger.debug "nginx redirect #{url}"
        return [200, { "X-Accel-Redirect" => url }, ""]
      else
        logger.debug "send_file #{patchage_path}"
        return send_file package_path
      end
    end

    def upload_droplet(id)
      handle_file_upload(id, "droplet")
    end

    def upload_artifact_cache(id)
      handle_file_upload(id, "artifact_cache")
    end

    def download_droplet(id)
      handle_file_download(id, "droplet")
    end

    def download_artifact_cache(id)
      handle_file_download(id, "artifact_cache")
    end

    private

    def handle_file_download(id, type)
      raise InvalidRequest unless LegacyStaging.local?

      app = Models::App.find(:guid => id)
      raise AppNotFound.new(id) if app.nil?

      path = LegacyStaging.local_path(id, type)
      logger.debug "id: #{id} #{type} path: #{path}"

      unless path
        logger.error "could not find #{type} file for #{id}"
        raise StagingError.new("#{type} file not found for #{id}")
      end

      if config[:nginx][:use_nginx]
        url = LegacyStaging.file_uri(id, type)
        logger.debug "nginx redirect #{url}"
        return [200, { "X-Accel-Redirect" => url }, ""]
      else
        logger.debug "send_file #{path}"
        return send_file path
      end
    end

    def handle_file_upload(id, key)
      app = Models::App.find(:guid => id)
      raise AppNotFound.new(id) if app.nil?
      handle = self.class.lookup_handle(id)
      raise StagingError.new("staging not in progress for #{id}") unless handle

      raise StagingError.new("malformed artifact cache upload request for #{id}") unless file_upload_param(key)
      upload_path = file_upload_param(key).path

      final_path = save_path(id, key)
      logger.debug "renaming #{key} file from '#{upload_path}' to '#{final_path}'"

      begin
        File.rename(upload_path, final_path)
      rescue => e
        raise StagingError.new("failed renaming #{key} file: #{e}")
      end

      handle.set_path(key, final_path)
      logger.debug "uploaded #{key} file for #{id} to #{final_path}"
      HTTP::OK
    end

    def file_upload_param(key)
      if config[:nginx][:use_nginx]
        Struct.new(:path).new(params["#{key}_path"])
      else
        params["upload"][key][:tempfile]
      end
    rescue
      nil
    end

    def save_path(id, prefix)
      File.join(tmpdir, "#{prefix}_#{id}.tgz")
    end

    def tmpdir
      (config[:directories] && config[:directories][:tmpdir]) || Dir.tmpdir
    end

    # TODO: put this back to all of staging once we change the auth scheme
    # (and add a test for /staging/droplets with bad auth)
    controller.before "#{APP_PATH}/*" do
      auth =  Rack::Auth::Basic::Request.new(env)
      unless (auth.provided? && auth.basic? && auth.credentials &&
              auth.credentials == [@config[:staging][:auth][:user],
                                   @config[:staging][:auth][:password]])
        raise NotAuthorized
      end
    end

    get  "/staging/apps/:id", :download_app
    get  "/staging/artifact-caches/:id", :download_artifact_cache
    post "/staging/artifact-caches/:id", :upload_artifact_cache
    post "/staging/droplets/:id", :upload_droplet
    get  "/staged_droplets/:id", :download_droplet
  end
end
