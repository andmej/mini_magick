require 'tempfile'

module MiniMagick
  class << self
    attr_accessor :processor
    attr_accessor :use_subexec
    attr_accessor :timeout
  end
  
  # Subexec only works with 1.9
  if RUBY_VERSION[0..2].to_f < 1.8
    self.use_subexec = true
    require 'subexec'
  end
  
  class Error < RuntimeError; end
  class Invalid < StandardError; end

  class Image
    attr :path
    attr :tempfile
    attr :output

    # Class Methods
    # -------------
    class << self
      def from_blob(blob, ext = nil)
        begin
          tempfile = Tempfile.new(['mini_magick', ext.to_s])
          tempfile.binmode
          tempfile.write(blob)
        ensure
          tempfile.close if tempfile
        end

        return self.new(tempfile.path, tempfile)
      end

      # Use this if you don't want to overwrite the image file
      def open(image_path)
        File.open(image_path, "rb") do |f|
          self.from_blob(f.read, File.extname(image_path))
        end
      end
      alias_method :from_file, :open
    end

    # Instance Methods
    # ----------------
    def initialize(input_path, tempfile=nil)
      @path = input_path
      @tempfile = tempfile # ensures that the tempfile will stick around until this image is garbage collected.

      # Ensure that the file is an image
      run_command("identify", @path)
    end

    # For reference see http://www.imagemagick.org/script/command-line-options.php#format
    def [](value)
      # Why do I go to the trouble of putting in newlines? Because otherwise animated gifs screw everything up
      case value.to_s
      when "format"
        run_command("identify", "-format", format_option("%m"), @path).split("\n")[0]
      when "height"
        run_command("identify", "-format", format_option("%h"), @path).split("\n")[0].to_i
      when "width"
        run_command("identify", "-format", format_option("%w"), @path).split("\n")[0].to_i
      when "dimensions"
        run_command("identify", "-format", format_option("%w %h"), @path).split("\n")[0].split.map{|v|v.to_i}
      when "size"
        File.size(@path) # Do this because calling identify -format "%b" on an animated gif fails!
      when "original_at"
        # Get the EXIF original capture as a Time object
        Time.local(*self["EXIF:DateTimeOriginal"].split(/:|\s+/)) rescue nil
      when /^EXIF\:/i
        result = run_command('identify', '-format', "\"%[#{value}]\"", @path).chop
        if result.include?(",")
          read_character_data(result)
        else
          result
        end
      else
        run_command('identify', '-format', "\"#{value}\"", @path).split("\n")[0]
      end
    end

    # Sends raw commands to imagemagick's mogrify command. The image path is automatically appended to the command
    def <<(*args)
      run_command("mogrify", *args << @path)
    end

    # This is a 'special' command because it needs to change @path to reflect the new extension
    # Formatting an animation into a non-animated type will result in ImageMagick creating multiple
    # pages (starting with 0).  You can choose which page you want to manipulate.  We default to the
    # first page.
    def format(format, page=0)
      run_command("mogrify", "-format", format, @path)

      old_path = @path.dup
      @path.sub!(/(\.\w*)?$/, ".#{format}")
      File.delete(old_path) unless old_path == @path

      unless File.exists?(@path)
        begin
          FileUtils.copy_file(@path.sub(".#{format}", "-#{page}.#{format}"), @path)
        rescue => ex
          raise MiniMagickError, "Unable to format to #{format}; #{ex}" unless File.exist?(@path)
        end
      end
    ensure
      Dir[@path.sub(/(\.\w+)?$/, "-[0-9]*.#{format}")].each do |fname|
        File.unlink(fname)
      end
    end
    
    # Collapse images with sequences to the first frame (ie. animated gifs) and
    # preserve quality
    def collapse!
      run_command("mogrify", "-quality", "100", "#{path}[0]")
    end

    # Writes the temporary image that we are using for processing to the output path
    def write(output_path)
      FileUtils.copy_file @path, output_path
      run_command "identify", output_path # Verify that we have a good image
    end

    # Give you raw data back
    def to_blob
      f = File.new @path
      f.binmode
      f.read
    ensure
      f.close if f
    end

    # If an unknown method is called then it is sent through the morgrify program
    # Look here to find all the commands (http://www.imagemagick.org/script/mogrify.php)
    def method_missing(symbol, *args)
      args.push(@path) # push the path onto the end
      run_command("mogrify", "-#{symbol}", *args)
      self
    end

    # You can use multiple commands together using this method
    def combine_options(&block)
      c = CommandBuilder.new
      block.call c
      run_command("mogrify", *c.args << @path)
    end

    # Check to see if we are running on win32 -- we need to escape things differently
    def windows?
      !(RUBY_PLATFORM =~ /win32/).nil?
    end

    # Outputs a carriage-return delimited format string for Unix and Windows
    def format_option(format)
      windows? ? "#{format}\\n" : "#{format}\\\\n"
    end

    def run_command(command, *args)
      args.collect! do |arg|        
        # args can contain characters like '>' so we must escape them, but don't quote switches
        if arg !~ /^[\+\-]/
          "\"#{arg}\""
        else
          arg.to_s
        end
      end

      command = "#{MiniMagick.processor} #{command} #{args.join(' ')}".strip

      if ::MiniMagick.use_subexec
        sub = Subexec.run(command, :timeout => MiniMagick.timeout)
        exit_status = sub.exitstatus
        output = sub.output
      else
        output = `#{command} 2>&1`
        exit_status = $?.exitstatus
      end
      
      if exit_status != 0
        # Clean up after ourselves in case of an error
        destroy!
        
        # Raise the appropriate error
        if output =~ /no decode delegate/i || output =~ /did not return an image/i
          raise Invalid, output
        else
          raise Error, "Command (#{command.inspect}) failed: #{{:status_code => exit_status, :output => output}.inspect}"
        end
      else
        output
      end
    end
    
    def destroy!
      return if tempfile.nil?
      File.unlink(tempfile.path)
      @tempfile = nil
    end
    
    private
      # Sometimes we get back a list of character values
      def read_character_data(list_of_characters)
        chars = list_of_characters.gsub(" ", "").split(",")
        result = ""
        chars.each do |val|
          result << ("%c" % val.to_i)
        end
        result
      end
  end

  class CommandBuilder
    attr :args

    def initialize
      @args = []
    end

    def method_missing(symbol, *args)
      @args << "-#{symbol}"
      @args += args
    end

    def +(value)
      @args << "+#{value}"
    end
  end
end
