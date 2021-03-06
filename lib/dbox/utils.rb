module Dbox
  module Utils
    def times_equal?(t1, t2)
      time_to_s(t1) == time_to_s(t2)
    end

    def time_to_s(t)
      case t
      when Time
        # matches dropbox time format
        t.utc.strftime("%a, %d %b %Y %H:%M:%S +0000")
      when String
        t
      end
    end

    def parse_time(t)
      case t
      when Time
        t
      when String
        Time.parse(t)
      end
    end

    # assumes local_path is defined
    def local_to_relative_path(path)
      if path =~ /^#{local_path}\/?(.*)$/i
        $1
      else
        raise BadPath, "Not a local path: #{path}"
      end
    end

    # assumes remote_path is defined
    def remote_to_relative_path(path)
      if path =~ /^#{remote_path}\/?(.*)$/i
        $1
      else
        raise BadPath, "Not a remote path: #{path}"
      end
    end

    # assumes local_path is defined
    def relative_to_local_path(path)
      if path && path.length > 0
        case_insensitive_join(local_path, path)
      else
        case_insensitive_resolve(local_path)
      end
    end

    # assumes remote_path is defined
    def relative_to_remote_path(path)
      if path && path.length > 0
        File.join(remote_path, path)
      else
        remote_path
      end
    end

    def case_insensitive_resolve(path)
      if File.exists?(path)
        path
      else
        matches = Dir.glob(path, File::FNM_CASEFOLD)
        case matches.size
        when 0 then path
        when 1 then matches.first
        else raise(RuntimeError, "Oops, you have multiple files with the same case. Please delete one of them, as Dropbox is case insensitive. (#{matches.join(', ')})")
        end
      end
    end

    def case_insensitive_join(path, *rest)
      if rest.length == 0
        case_insensitive_resolve(path)
      else
        rest = rest.map {|s| s.split(File::SEPARATOR) }.flatten
        case_insensitive_join(File.join(case_insensitive_resolve(path), rest[0]), *rest[1..-1])
      end
    end

    def case_insensitive_difference(a, b)
      b = b.map(&:downcase).sort
      a.reject {|s| b.include?(s.downcase) }
    end

    def case_insensitive_equal(a, b)
      a && b && a.downcase == b.downcase
    end

    # Calculate the content hash of the file found at path
    def content_hash_file(path)
      io = File.open(path)
      content_hash(io)
    rescue Errno::EISDIR
      nil
    rescue Errno::ENOENT
      nil
    end

    # content_hash algorithm as described here: https://www.dropbox.com/developers/reference/content-hash
    # 1. Split the file into blocks of 4 MB (4,194,304 or 4 * 1024 * 1024 bytes). The last block may be smaller than 4 MB.
    # 2. Compute the hash of each block using SHA-256.
    # 3. Concatenate the hash of all blocks in the binary format to form a single binary string.
    # 4. Compute the hash of the concatenated string using SHA-256. Output the resulting hash in hexadecimal format.
    def content_hash(io)
      chunksize = 4 * 1024 * 1024
      sha = ''
      until io.eof do
        sha << Digest::SHA256.digest(io.read(chunksize))
      end
      Digest::SHA256.hexdigest(sha)
    end

    def find_nonconflicting_path(filepath)
      proposed = filepath
      while File.exists?(case_insensitive_resolve(proposed))
        dir, p = File.split(proposed)
        p = p.sub(/^(.*?)( \((\d+)\))?(\..*?)?$/) { "#{$1} (#{$3 ? $3.to_i + 1 : 1})#{$4}" }
        proposed = File.join(dir, p)
      end
      proposed
    end
  end
end
