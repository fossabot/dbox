def case_insensitive_resolve(path)
  if File.exists?(path)
    path
  else
    case_insensitive_path = path.gsub(/([a-zA-Z])/) { |match| "[#{$1.downcase}#{$1.upcase}]" }
    matches = Dir.glob(case_insensitive_path)

    # if foo.txt does not exist, but foo.txt.txt does, then we want to find that
    # also, we want to match foo.jpg.jpeg with foo.jpeg.jpeg or foo.jpg or foo.jpeg or ...
    if matches.empty? && !File.extname(path).empty?
      matches = Dir.glob(case_insensitive_path + File.extname(case_insensitive_path), File::FNM_CASEFOLD)
    end
    if matches.empty? && !File.extname(path).empty? && [".jpg", ".jpeg"].include?(File.extname(path).downcase)
      path_without_extension = path.sub(/\.jpe?g$/, "")
      case_insensitive_path_without_extension = path_without_extension.gsub(/([a-zA-Z])/) { |match| "[#{$1.downcase}#{$1.upcase}]" }
      matches =
        Dir.glob(case_insensitive_path_without_extension + "{.jpg,.jpeg}") +
        Dir.glob(case_insensitive_path_without_extension + "{.jpg,.jpeg}{.jpg,.jpeg}")
    end
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

def case_insensitive_include?(arr, str)
  arr.map {|f| f.downcase }.include?(str.downcase)
end

module CaseInsensitiveFile
  def self.resolve(path)
    case_insensitive_resolve(path)
  end

  def self.join(*args)
    case_insensitive_join(*args)
  end

  def self.fix_relpath_case(relpath, base)
    join(base, relpath).sub(/^#{base}\/?/i, "")
  end

  def self.exist?(path)
    File.exist?(resolve(path))
  end

  def self.exists?(path)
    File.exists?(resolve(path))
  end

  def self.directory?(path)
    File.directory?(resolve(path))
  end

  def self.file?(path)
    File.file?(resolve(path))
  end

  def self.read(path)
    File.read(resolve(path))
  end

  def self.open(path, mode, &proc)
    File.open(resolve(path), mode, &proc)
  end

  def self.size(path)
    File.size(resolve(path))
  end

  def self.mkdir_p(path)
    FileUtils.mkdir_p(resolve(path))
  end

  def self.rm_rf(path)
    paths = [path].flatten.map { |p| resolve(p)}

    FileUtils.rm_rf(paths)
  end

  def self.rm_f(path)
    paths = [path].flatten.map { |p| resolve(p)}

    FileUtils.rm_f(paths)
  end

  def self.cp(from, to)
    FileUtils.cp(resolve(from), resolve(to))
  end

  def self.mv(from, to)
    FileUtils.mv(resolve(from), resolve(to))
  end

  def self.glob(expr)
    Dir.glob(expr, File::FNM_CASEFOLD)
  end

  def self.basename(path, suffix = nil)
    if suffix
      File.basename(resolve(path), suffix)
    else
      File.basename(resolve(path))
    end
  end

  def self.dirname(path)
    File.dirname(resolve(path))
  end
end
