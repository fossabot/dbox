require 'case_insensitive_utils'
require 'find'

module Dbox
  class Syncer
    include CaseInsensitiveFile

    MIN_BYTES_TO_STREAM_DOWNLOAD = 1024 * 100 # 100kB

    include Loggable

    def self.create(remote_path, local_path)
      api.create_dir(remote_path)
      clone(remote_path, local_path)
    end

    def self.clone(remote_path, local_path, params = {})
      api.metadata(remote_path) # ensure remote exists
      database = Database.create(remote_path, local_path)
      Pull.new(database, api, params).execute
    end

    def self.pull(local_path, params = {})
      database = Database.load(local_path)
      Pull.new(database, api, params).execute
    end

    def self.push(local_path, params = {})
      database = Database.load(local_path)
      Push.new(database, api, params).execute
    end

    def self.move(new_remote_path, local_path)
      database = Database.load(local_path)
      api.move(database.metadata[:remote_path], new_remote_path)
      database.update_metadata(:remote_path => new_remote_path)
    end

    def self.api
      @@_api ||= API.connect
    end

    class Operation
      include Loggable
      include Utils

      attr_reader :database

      def initialize(database, api, params = {})
        @database = database
        @api = api
        @params = params
      end

      def practice
        @practice = true
        changes = execute
        log.debug "Changes that would be executed:\n" + changes.map {|c| c.inspect }.join("\n")
      ensure
        @practice = false
      end

      def params
        @params
      end

      def api
        @api
      end

      def metadata
        @_metadata ||= database.metadata
      end

      # path should be a relative path
      def in_subdir?(path)
        local_subdirs.any? { |dir| path =~ /^#{dir}/ }
      end

      def local_path
        metadata[:local_path]
      end

      def remote_path
        metadata[:remote_path]
      end

      def blacklisted_extensions
        params[:blacklisted_extensions]
      end

      def remove_dotfiles(files)
        files.reject {|f| File.basename(f.path_lower).start_with?(".") }
      end

      def remove_blacklisted_extensions(files)
        return files unless blacklisted_extensions
        files.reject { |f| f.is_a?(Dropbox::FileMetadata) && blacklisted_extensions.include?(File.extname(f.path_lower))}
      end

      def remote_subdirs
        return unless params[:subdir]
        params[:subdir].split(/,/).map do |dir|
          File.join(remote_path, dir)
        end
      end

      def local_subdirs
        return unless params[:subdir]
        params[:subdir].split(/,/)
      end

      def entries_hash_by_path
        out = InsensitiveHash.new
        database.contents.each_with_object(InsensitiveHash.new) do |entry, h|
          h[entry[:path_lower]] = entry if entry[:path_lower]
        end
      end

      def entries_hash_by_dropbox_id
        database.contents.each_with_object(InsensitiveHash.new) do |entry, h|
          h[entry[:dropbox_id]] = entry if entry[:dropbox_id]
        end
      end

      def current_dir_entries_as_hash(dir)
        if dir[:id]
          out = InsensitiveHash.new
          out[dir[:path]] = dir
          database.contents.each {|e| out[e[:path]] = e }
          out
        else
          {}
        end
      end

      def lookup_id_by_path(path)
        @_ids ||= {}
        @_ids[path] ||= database.find_by_path(path)[:id]
      end

      def saving_timestamp(path)
        path = CaseInsensitiveFile.resolve(path)
        mtime = File.mtime(path)
        res = yield
        File.utime(Time.now, mtime, path)
        res
      end

      def saving_parent_timestamp(entry, &proc)
        parent = File.dirname(entry[:local_path])
        saving_timestamp(parent, &proc)
      end

      def update_file_timestamp(entry)
        begin
          File.utime(Time.now, entry[:modified], entry[:local_path])
        rescue Errno::ENOENT
          nil
        end
      end

      def gather_remote_info
        res = api.list_folder(database.metadata[:remote_path], recursive: true, get_all: true)
        if res.is_a?(Array) && res.all? {|r| r.is_a?(Dropbox::FileMetadata) || r.is_a?(Dropbox::FolderMetadata)}
          res = remove_dotfiles(res)
          res = remove_blacklisted_extensions(res)
          res
        else
          raise(RuntimeError, "Invalid result from server: #{res.inspect}")
        end
      end

      def generate_tmpfilename(path)
        out = CaseInsensitiveFile.join(local_path, ".#{path.gsub(/\W/, '-')}.part")
        if CaseInsensitiveFile.exists?(out)
          generate_tmpfilename("path#{rand(1_000_000)}")
        else
          out
        end
      end

      def remove_tmpfiles
        Dir["#{local_path}/.*.part"].each {|f| CaseInsensitiveFile.rm_f(f) }
      end

      def sort_changelist(changelist)
        changelist.keys.each do |k|
          case k
          when :failed
            changelist[k].sort! {|c1, c2| c1[:path] <=> c2[:path] }
          when :moved
            changelist[k].sort! {|c1, c2| c1[:path] <=> c2[:path] }
          else
            changelist[k].sort!
          end
        end
        changelist
      end
    end

    class Pull < Operation
      def initialize(database, api, params = {})
        super(database, api, params)
      end

      def execute
        remove_tmpfiles
        dir = database.local_path
        found_paths = []
        existing_entries_by_path = entries_hash_by_path
        existing_entries_by_dropbox_id = entries_hash_by_dropbox_id
        changelist = {created: [], deleted: [], updated: [], failed: [], moved: []}
        # grab the metadata for the current dir from Dropbox
        contents = gather_remote_info

        # The first time you download via V2 of the API, you need to stick the
        # dropbox_id in the DB.
        # We don't do this in the migration as the DB class has no access to the
        # API.
        database.contents.reject { |entry| entry[:dropbox_id] }.each do |entry|
          matching_content = contents.detect do |content|
            content.is_a?(Dropbox::FileMetadata) && remote_to_relative_path(content.path_lower) == entry[:path_lower]
          end
          database.update_entry_by_id(entry[:id], dropbox_id: matching_content.id ) if matching_content
        end

        # Filter to the selected subdirs if the subdir param was used
        contents = contents.select {|c| in_subdir?(remote_to_relative_path(c.path_lower))} if local_subdirs

        # process each entry that came back from dropbox/filesystem
        contents.each do |c|
          relative_path = remote_to_relative_path(c.path_lower)
          relative_path_display = remote_to_relative_path(c.path_display)
          local_path = relative_to_local_path(relative_path)
          local_path_display = relative_to_local_path(relative_path_display)
          remote_path = c.path_lower
          # Dropbox::FileMetadata => file. Dropbox::FolderMetadata => folder
          meta_type = c.class.to_s.split(/::/).last.sub('Metadata', '').downcase
          log.debug("Executing changes for #{c.path_lower} of type #{meta_type}")
          case meta_type
          when 'folder'
            found_paths << relative_path
            create_dir(local_path_display)
          when 'file'
            updated_entry = {
              dropbox_id: c.id,
              path_lower: remote_to_relative_path(c.path_lower),
              path_display: remote_to_relative_path(c.path_display),
              local_hash: c.content_hash,
              modified: c.server_modified,
              revision: c.rev
            }
            create_dir(CaseInsensitiveFile.dirname(local_path_display))
            found_paths << relative_path
            if entry = existing_entries_by_dropbox_id[c.id]
              changed = false
              # Move if necessary
              current_local_path = relative_to_local_path(entry[:path_lower])
              if current_local_path != local_path && CaseInsensitiveFile.exist?(current_local_path)
                log.debug("moving #{current_local_path} to #{local_path_display}")
                move_file(current_local_path, local_path_display)
                changelist[:moved] << {current_local_path => local_path_display}
                changed = true
              end

              # Download if necessary
              content_hash = content_hash_file(local_path)
              if content_hash != c.content_hash
                log.debug("Updating #{local_path_display}")
                res = download_file(local_path_display, remote_path, c.size)
                changed = true
                changelist[:updated] << local_path
              end

              if changed && !@practice
                database.update_entry_by_dropbox_id(c.id, updated_entry)
              end
            else
              # Create the new file
              res = download_file(local_path_display, remote_path, c.size)
              # TODO Add the new file to the DB
              changelist[:created] << local_path_display
              log.debug("Creating #{local_path_display}")
              database.add_entry(updated_entry) unless @practice
            end
          end

        end

          # Files in the DB that are not on Dropbox
        dirs = case_insensitive_difference(existing_entries_by_path.keys, found_paths)
        # Files in the local filesystem that are not on Dropbox
        local_dirs = []
        Find.find(dir) do |path|
          Find.prune if File.basename(path)[0] == ?.
          local_dirs << local_to_relative_path(path)
        end
        dirs += case_insensitive_difference(local_dirs, found_paths)

        dirs.uniq!
        dirs = dirs.select { |file| in_subdir?(file)} if local_subdirs
        log.debug("Deleting these dirs:")
        log.debug(dirs)
        dirs.each do |p|
          delete_file_or_folder_and_db_entry(p, changelist)
        end

        # sort & return output
        sort_changelist(changelist)
      end

      def delete_file_or_folder_and_db_entry(path_lower, changelist)
        local_path = relative_to_local_path(path_lower)
        if CaseInsensitiveFile.exist?(local_path)
          if CaseInsensitiveFile.file?(local_path)
            delete_file(local_path)
            # TODO remove the entry from the DB
          else
            delete_dir(local_path)
          end
          database.idempotent_delete_entry_by_path(path_lower) unless @practice
          changelist[:deleted] << local_path
        end
      end

      def modified?(entry, res)
        out = (entry[:revision] != res[:revision]) ||
              !times_equal?(entry[:modified], res[:modified])
        out ||= (entry[:remote_hash] != res[:remote_hash]) if res.has_key?(:remote_hash)
        log.debug "#{entry[:path]} modified? r#{entry[:revision]} vs. r#{res[:revision]}, h#{entry[:remote_hash]} vs. h#{res[:remote_hash]}, t#{time_to_s(entry[:modified])} vs. t#{time_to_s(res[:modified])} => #{out}"
        out
      end

      def create_dir(local_path)
        log.info "Creating #{local_path}"
        return :exists if CaseInsensitiveFile.exists?(local_path)
        return if @practice
        CaseInsensitiveFile.mkdir_p(local_path)
      end

      def delete_dir(local_path)
        log.info "Deleting #{local_path}"
        return if @practice
        CaseInsensitiveFile.rm_rf(local_path)
      end

      def delete_file(local_path)
        log.info "Deleting file: #{local_path}"
        return if @practice
        CaseInsensitiveFile.rm_f(local_path)
      end

      def move_file(original_local_path, final_local_path)
        return if @practice
        CaseInsensitiveFile.mv(original_local_path, final_local_path)
      end

      def download_file(local_path, remote_path, size)
        return if @practice
        local_path = CaseInsensitiveFile.resolve(local_path)
        path_lower = local_to_relative_path(local_path).downcase

        # stream files larger than the minimum
        stream = size && size > MIN_BYTES_TO_STREAM_DOWNLOAD

        # download to temp file
        tmp = generate_tmpfilename(path_lower)
        CaseInsensitiveFile.open(tmp, "wb") do |f|
          api.get_file(remote_path, f, stream)
        end

        # atomic move over to the real file
        CaseInsensitiveFile.mv(tmp, local_path)

        true
      end

    end

    class Push < Operation
      def initialize(database, api, params = {})
        super(database, api, params)
      end

      def execute
        dir = database.local_path
        changes = calculate_changes(dir)
        log.debug "Executing changes:\n" + changes.map {|c| c.inspect }.join("\n")
        changelist = { :created => [], :deleted => [], :updated => [], :failed => [] }

        changes.each do |op, c|
          # We want to include paths up to and including the remote_subdirs, and also paths that have the remote_subdirs as their root
          if remote_subdirs && !remote_subdirs.any? {|dir| c[:remote_path].index(dir) == 0 || dir.index(c[:remote_path]) == 0}
            if op == :create && c[:is_dir] && !database.find_by_path(c[:path])
              database.add_entry(c[:path], true, c[:parent_id], c[:modified], c[:revision], nil, nil)
            end
            next
          end

          case op
          when :create
            c[:parent_id] ||= lookup_id_by_path(c[:parent_path])

            if c[:is_dir]
              # create the remote directiory
              create_dir(c)
              database.find_by_path(c[:path]) ? database.update_entry_by_path(c[:path], :modified => c[:modified], :revision => c[:revision], :remote_hash => c[:remote_hash]) : database.add_entry(c[:path], true, c[:parent_id], nil, nil, nil, nil)
              force_metadata_update_from_server(c)
              changelist[:created] << c[:path]
            else
              # upload a new file
              begin
                local_hash = content_hash_file(c[:local_path])
                res = upload_file(c)
                database.add_entry(c[:path], false, c[:parent_id], nil, nil, nil, local_hash)
                if case_insensitive_equal(c[:path], res[:path])
                  force_metadata_update_from_server(c)
                  changelist[:created] << c[:path]
                else
                  log.warn "#{c[:path]} had a conflict and was renamed to #{res[:path]} on the server"
                  changelist[:conflicts] ||= []
                  changelist[:conflicts] << { :original => c[:path], :renamed => res[:path] }
                end
              rescue => e
                log.error "Error while uploading #{c[:path]}: #{e.inspect}\n#{e.backtrace.join("\n")}"
                changelist[:failed] << { :operation => :create, :path => c[:path], :error => e }
              end
            end
          when :update
            existing = database.find_by_path(c[:path])
            unless existing[:is_dir] == c[:is_dir]
              raise(RuntimeError, "Mode on #{c[:path]} changed between file and dir -- not supported yet")
            end

            # only update files -- nothing to do to update a dir
            if !c[:is_dir]
              # upload changes to a file
              begin
                local_hash = content_hash_file(c[:local_path])
                res = upload_file(c)
                database.update_entry_by_path(c[:path], :local_hash => local_hash)
                if case_insensitive_equal(c[:path], res[:path])
                  force_metadata_update_from_server(c)
                  changelist[:updated] << c[:path]
                else
                  log.warn "#{c[:path]} had a conflict and was renamed to #{res[:path]} on the server"
                  changelist[:conflicts] ||= []
                  changelist[:conflicts] << { :original => c[:path], :renamed => res[:path] }
                end
              rescue => e
                log.error "Error while uploading #{c[:path]}: #{e.inspect}\n#{e.backtrace.join("\n")}"
                changelist[:failed] << { :operation => :update, :path => c[:path], :error => e }
              end
            end
          when :delete
            # delete a remote file/directory
            begin
              begin
                if c[:is_dir]
                  delete_dir(c)
                else
                  delete_file(c)
                end
              rescue Dbox::RemoteMissing
                # safe to delete even if remote is already gone
              end
              database.delete_entry_by_path(c[:path])
              changelist[:deleted] << c[:path]
            rescue => e
              log.error "Error while deleting #{c[:path]}: #{e.inspect}\n#{e.backtrace.join("\n")}"
              changelist[:failed] << { :operation => :delete, :path => c[:path], :error => e }
            end
          when :failed
            changelist[:failed] << { :operation => c[:operation], :path => c[:path], :error => c[:error] }
          else
            raise(RuntimeError, "Unknown operation type: #{op}")
          end
        end

        # sort & return output
        sort_changelist(changelist)
      end

      def calculate_changes(dir)
        raise(ArgumentError, "Not a directory: #{dir.inspect}") unless dir[:is_dir]

        out = []

        existing_entries = current_dir_entries_as_hash(dir)
        child_paths = list_contents(dir).sort

        child_paths.each do |p|
          local_path = relative_to_local_path(p)
          remote_path = relative_to_remote_path(p)
          c = {
            :path => p,
            :local_path => local_path,
            :remote_path => remote_path,
            :modified => mtime(local_path),
            :is_dir => is_dir(local_path),
            :parent_path => dir[:path],
            :local_hash => content_hash_file(local_path)
          }
          if entry = existing_entries[p]
            c[:id] = entry[:id]
            out << [:update, c] if modified?(entry, c) # update iff modified
          else
            # create
            out << [:create, c]
          end
        end

        # add any deletions
        out += case_insensitive_difference(existing_entries.keys, child_paths).map do |p|
          [:delete, existing_entries[p]]
        end

        # recursively process new & existing subdirectories
        recur_dirs.each do |dir|
          out += calculate_changes(dir)
        end

        out
      end

      def mtime(path)
        File.mtime(CaseInsensitiveFile.resolve(path))
      end

      def is_dir(path)
        CaseInsensitiveFile.directory?(CaseInsensitiveFile.resolve(path))
      end

      def modified?(entry, res)
        out = true
        if entry[:is_dir]
          out = !times_equal?(entry[:modified], res[:modified])
          log.debug "#{entry[:path]} modified? t#{time_to_s(entry[:modified])} vs. t#{time_to_s(res[:modified])} => #{out}"
        else
          eh = entry[:local_hash]
          rh = res[:local_hash]
          out = !(eh && rh && eh == rh)
          log.debug "#{entry[:path]} modified? #{eh} vs. #{rh} => #{out}"
        end
        out
      end

      def list_contents(dir)
        local_path = dir[:local_path]
        paths = Dir.entries(local_path).reject {|s| s == "." || s == ".." || s.start_with?(".") }
        paths.map {|p| local_to_relative_path(File.join(local_path, p)) }
      end

      def create_dir(dir)
        remote_path = dir[:remote_path]
        log.info "Creating #{remote_path}"
        api.create_dir(remote_path)
      end

      def delete_dir(dir)
        remote_path = dir[:remote_path]
        api.delete_dir(remote_path)
      end

      def delete_file(file)
        remote_path = file[:remote_path]
        api.delete_file(remote_path)
      end

      def upload_file(file)
        local_path = file[:local_path]
        remote_path = file[:remote_path]
        db_entry = database.find_by_path(file[:path])
        last_revision = db_entry ? db_entry[:revision] : nil
        res = api.put_file(remote_path, local_path, last_revision)
      end

      def force_metadata_update_from_server(entry)
        res = gather_remote_info
        unless res == :not_modified
          database.update_entry_by_path(entry[:path], :modified => res[:modified], :revision => res[:revision], :remote_hash => res[:remote_hash])
        end
        update_file_timestamp(database.find_by_path(entry[:path]))
      end
    end
  end
end
