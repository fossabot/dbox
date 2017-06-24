require 'net/http'

module Dbox
  NUM_TRIES = 3
  TIME_BETWEEN_TRIES = 3 # in seconds

  class ConfigurationError < RuntimeError; end
  class ServerError < RuntimeError; end
  class RemoteMissing < RuntimeError; end
  class RemoteAlreadyExists < RuntimeError; end
  class RequestDenied < RuntimeError; end
  class InvalidResponse < RuntimeError; end

  class API
    include Loggable

    def self.authorize
      app_key = ENV["DROPBOX_APP_KEY"]
      app_secret = ENV["DROPBOX_APP_SECRET"]

      raise(ConfigurationError, "Please set the DROPBOX_APP_KEY environment variable to a Dropbox application key") unless app_key
      raise(ConfigurationError, "Please set the DROPBOX_APP_SECRET environment variable to a Dropbox application secret") unless app_secret


      flow = DropboxOAuth2FlowNoRedirect.new(app_key, app_secret)
      authorize_url = flow.start()

      puts '1. Go to: ' + authorize_url
      puts '2. Click "Allow" (you might have to log in first)'
      puts '3. Copy the authorization code'
      print 'Enter the authorization code here: '
      code = STDIN.readline.strip

      # This will fail if the user gave us an invalid authorization code
      access_token, user_id = flow.finish(code)

      puts "export DROPBOX_ACCESS_TOKEN=#{access_token}"
      puts "export DROPBOX_USER_ID=#{user_id}"
      puts
      puts "This auth token will last for 10 years, or when you choose to invalidate it, whichever comes first."
      puts
      puts "Now either include these constants in yours calls to dbox, or set them as environment variables."
      puts "In bash, including them in calls looks like:"
      puts "$ DROPBOX_ACCESS_TOKEN=#{access_token} DROPBOX_USER_ID=#{user_id} dbox ..."
    end

    def self.connect
      api = new()
      api.connect
      api
    end

    attr_reader :client

    # IMPORTANT: API.new is private. Please use API.authorize or API.connect as the entry point.
    private_class_method :new
    def initialize
    end

    def initialize_copy(other)
      @client = other.client.clone()
    end

    def connect
      access_token = ENV["DROPBOX_ACCESS_TOKEN"]
      access_type = ENV["DROPBOX_ACCESS_TYPE"] || "dropbox"

      raise(ConfigurationError, "Please set the DROPBOX_ACCESS_TOKEN environment variable to a Dropbox access token") unless access_token
      raise(ConfigurationError, "Please set the DROPBOX_ACCESS_TYPE environment variable either dropbox (full access) or sandbox (App access)") unless access_type == "dropbox" || access_type == "app_folder"
      @client = Dropbox::Client.new(access_token)
    end

    def run(path, tries = NUM_TRIES, &proc)
      begin
        res = proc.call
        handle_response(path, res) { raise RuntimeError, "Unexpected result: #{res.inspect}" }
      end
    end

    def handle_response(path, res, &else_proc)
      case res
      when Dropbox::DeletedMetadata
        raise RemoveMissing, "#{path} has been deleted"
      when Dropbox::FileMetadata, Dropbox::FolderMetadata
        res
      when Array
        res
      when Hash
        InsensitiveHash[res]
      when String
        res
      when ::Net::HTTPNotFound
        raise RemoteMissing, "#{path} does not exist on Dropbox"
      when ::Net::HTTPForbidden
        raise RequestDenied, "Operation on #{path} denied"
      when ::Net::HTTPNotModified
        :not_modified
      when true
        true
      else
        else_proc.call()
      end
    end

    def metadata(path = "/")
      run(path) do
        log.debug "Fetching metadata for #{path}"
        begin
          res = @client.get_metadata(path)#, 10000, list, hash)
          log.debug res.inspect
        rescue Dropbox::ApiError => e
          raise Dbox::RemoteMissing, "#{path} has been deleted on Dropbox" if e.message =~ /path\/not_found/
        end
        res
      end
    end

    def list_folder(path, recursive: false, get_all: true, include_deleted: false)
      run(path) do
        log.debug "Getting file listing for #{path}"
        begin
          res = @client.list_folder(path, recursive: recursive, get_all: get_all, include_deleted: include_deleted)
        rescue Dropbox::ApiError => e
          raise Dbox::RemoteMissing, "#{path} has been deleted on Dropbox" if e.message =~ /path\/not_found/
        end
      end
    end

    def create_dir(path)
      run(path) do
        log.info "Creating #{path}"
        begin
          @client.create_folder(path)
        rescue Dropbox::ApiError => e
          if e.message =~ /conflict/
            raise RemoteAlreadyExists, "Either the directory at #{path} already exists, or it has invalid characters in the name"
          else
            raise e
          end
        end
      end
    end

    def idempotent_delete_dir(path)
      delete_dir(path)
    rescue Dropbox::ApiError => e
      raise e unless e.message =~ /path_lookup\/not_found\//
    end

    def delete_dir(path)
      run(path) do
        log.info "Deleting #{path}"
        @client.delete(path)
      end
    end

    def get_file(path, file_obj, stream=false)
      unless stream
        # just download directly using the get_file API
        res = run(path) do
          log.info "Downloading #{path}"
          @client.download(path)
        end

        # client.download returns an array with Dropbox::FileMetadata
        # in the first element
        # and HTTP::Response::Body in the second
        if res.kind_of?(Array) && res.last.kind_of?(HTTP::Response::Body)
          file_obj << res.last.to_s
          true
        else
          raise Dbox::InvalidResponse
        end
      else
        # use the media API to get a URL that we can stream from, and
        # then stream the file to disk
        res = run(path) { @client.get_temporary_link(path) }
        url = res.last if res.kind_of?(Array) && res.last.respond_to?(:=~) && res.last =~ /^https?:\/\//
        if url
          log.info "Streaming #{path}"
          streaming_download(url, file_obj)
        else
          get_file(path, file_obj, false)
        end
      end
    end

    def put_file(path, local_path, previous_revision=nil)
      run(path) do
        log.info "Uploading #{path}"
        File.open(local_path, "r") {|f| @client.upload(path, f.read, mode: :overwrite) }
      end
    end

    def idempotent_delete_file(path)
      delete_file(path)
    rescue Dropbox::ApiError => e
      raise e unless e.message =~ /path_lookup\/not_found\//
    end

    def delete_file(path)
      run(path) do
        log.info "Deleting #{path}"
        @client.delete(path)
      end
    end

    def move(old_path, new_path)
      run(old_path) do
        log.info "Moving #{old_path} to #{new_path}"
        begin
          @client.move(old_path, new_path)
        rescue Dropbox::ApiError => e
          case e.message
          when /conflict/
            raise RemoteAlreadyExists, "Error during move -- there may already be a Dropbox folder at #{new_path}"
          when /not_found/
            raise RemoteMissing, "Error during move -- the dropbox folder or file you are trying to move does not exist"
          else
            raise e
          end
        end
      end
    end

    def streaming_download(url, io, num_redirects = 0)
      url = URI.parse(url)
      http = ::Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.ca_file = Dropbox::TRUSTED_CERT_FILE

      req = ::Net::HTTP::Get.new(url.request_uri)
      req["User-Agent"] = "dbox"

      http.request(req) do |res|
        if res.kind_of?(::Net::HTTPSuccess)
          # stream into given io
          res.read_body {|chunk| io.write(chunk) }
          true
        else
          if res.kind_of?(::Net::HTTPRedirection) && res.header['location'] && num_redirects < 10
            log.info("following redirect, num_redirects = #{num_redirects}")
            log.info("redirect url: #{res.header['location']}")
            streaming_download(res.header['location'], io, num_redirects + 1)
          else
            raise DropboxError.new("Invalid response #{res.inspect}")
          end
        end
      end
    end
  end
end
