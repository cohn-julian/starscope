module StarScope::Export

  # cscope has this funky issue where it refuses to recognize function calls that
  # happen outside of a function definition - this isn't an issue in C, where all
  # calls must occur in a function, but in ruby et al. it is perfectly legal to
  # write normal code outside the "scope" of a function definition - we insert a
  # fake shim "global" function everywhere we can to work around this
  CSCOPE_GLOBAL_HACK_START = "\n\t$-\n"
  CSCOPE_GLOBAL_HACK_STOP = "\n\t}\n"

  def export_ctags(file)
    file.puts <<END
!_TAG_FILE_FORMAT	2	/extended format/
!_TAG_FILE_SORTED	1	/0=unsorted, 1=sorted, 2=foldcase/
!_TAG_PROGRAM_AUTHOR	Evan Huus /eapache@gmail.com/
!_TAG_PROGRAM_NAME	StarScope //
!_TAG_PROGRAM_URL	https://github.com/eapache/starscope //
!_TAG_PROGRAM_VERSION	#{StarScope::VERSION}	//
END
    defs = (@tables[:defs] || {}).sort_by {|x| x[:name][-1].to_s}
    defs.each do |record|
      file.puts ctag_line(record, @meta[:files][record[:file]])
    end
  end

  # ftp://ftp.eeng.dcu.ie/pub/ee454/cygwin/usr/share/doc/mlcscope-14.1.8/html/cscope.html
  def export_cscope(file)
    buf = ""
    files = []
    db_by_line().each do |filename, lines|
      next if lines.empty?

      buf << "\t@#{filename}\n\n"
      buf << "0 #{CSCOPE_GLOBAL_HACK_START}\n"
      files << filename
      func_count = 0

      lines.sort.each do |line_no, records|
        line = line_for_record(records.first)
        toks = tokenize_line(line, records)
        next if toks.empty?

        prev = 0
        buf << line_no.to_s << " "
        toks.each do |offset, record|

          next if offset < prev # this probably indicates an extractor bug

          # Don't export nested functions, cscope barfs on them since C doesn't
          # have them at all. Skipping tokens is easy; since prev isn't updated
          # they get turned into plain text automatically.
          if record[:type] == :func
            case record[:tbl]
            when :defs
              func_count += 1
              next unless func_count == 1
            when :end
              func_count -= 1
              next unless func_count == 0
            end
          end

          buf << CSCOPE_GLOBAL_HACK_STOP if record[:type] == :func && record[:tbl] == :defs
          buf << cscope_plaintext(line, prev, offset) << "\n"
          buf << cscope_mark(record[:tbl], record) << record[:key] << "\n"
          buf << CSCOPE_GLOBAL_HACK_START if record[:type] == :func && record[:tbl] == :end

          prev = offset + record[:key].length

        end
        buf << cscope_plaintext(line, prev, line.length) << "\n\n"
      end
    end

    buf << "\t@\n"

    header = "cscope 15 #{Dir.pwd} -c "
    offset = "%010d\n" % (header.length + 11 + buf.bytes.count)

    file.print(header)
    file.print(offset)
    file.print(buf)

    file.print("#{@meta[:paths].length}\n")
    @meta[:paths].each {|p| file.print("#{p}\n")}
    file.print("0\n")
    file.print("#{files.length}\n")
    buf = ""
    files.each {|f| buf << f + "\n"}
    file.print("#{buf.length}\n#{buf}")
  end

  private

  def db_by_line()
    db = {}
    @tables.each do |tbl, records|
      records.each do |record|
        next if not record[:line_no]
        record[:tbl] = tbl
        db[record[:file]] ||= {}
        db[record[:file]][record[:line_no]] ||= []
        db[record[:file]][record[:line_no]] << record
      end
    end
    return db
  end

  def tokenize_line(line, records)
    toks = {}

    records.each do |record|
      key = record[:name][-1].to_s

      # use the column if we have it, otherwise fall back to scanning
      index = record[:col] || line.index(key)

      # keep scanning if our current index doesn't actually match the key, or if
      # either the preceeding or succeeding character is a word character
      # (meaning we've accidentally matched the middle of some other token)
      while !index.nil? &&
        ((line[index, key.length] != key) ||
         (index > 0 && line[index-1] =~ /\w/) ||
         (index+key.length < line.length && line[index+key.length] =~ /\w/))
        index = line.index(key, index+1)
      end

      next if index.nil?

      # Strip trailing non-word characters, otherwise cscope barfs on
      # function names like `include?`
      if key =~ /^\W*$/
        next unless [:defs, :end].include?(record[:tbl])
      else
        key.sub!(/\W+$/, '')
      end

      record[:key] = key
      toks[index] = record

    end

    return toks.sort
  end

  def cscope_plaintext(line, start, stop)
    ret = line.slice(start, stop-start)
    ret.lstrip! if start == 0
    ret.rstrip! if stop == line.length
    ret.gsub(/\s+/, ' ')
  rescue ArgumentError
    # invalid utf-8 byte sequence in the line, oh well
    line
  end

  def cscope_mark(tbl, rec)
    case tbl
    when :end
      case rec[:type]
      when :func
        ret = "}"
      else
        return ""
      end
    when :file
      ret = "@"
    when :defs
      case rec[:type]
      when :func
        ret = "$"
      when :class, :module
        ret = "c"
      when :type
        ret = "t"
      else
        ret = "g"
      end
    when :calls
      ret = "`"
    when :requires
      ret = "~\""
    when :imports
      ret = "~<"
    when :assigns
      ret = "="
    else
      return ""
    end

    return "\t" + ret
  end

  def ctag_line(rec, file)
    ret = "#{rec[:name][-1]}\t#{rec[:file]}\t/^#{line_for_record(rec)}$/"

    ext = ctag_ext_tags(rec, file)
    if not ext.empty?
      ret << ";\""
      ext.sort.each do |k, v|
        ret << "\t#{k}:#{v}"
      end
    end

    ret
  end

  def ctag_ext_tags(rec, file)
    tag = {}

    # these extensions are documented at http://ctags.sourceforge.net/FORMAT
    case rec[:type]
    when :func
      tag["kind"] = "f"
    when :module, :class
      tag["kind"] = "c"
    end

    tag["language"] = file[:lang]

    tag
  end

end