require 'zip/zip'
require 'jruby/jrubyc'

module Warbler
  # Class that holds the files that will be stored in the war file.
  # The #files attribute contains a hash of pathnames inside the war
  # file to their contents. Contents can be one of:
  # * +nil+ representing a directory entry
  # * Any object responding to +read+ representing an in-memory blob
  # * A String filename pointing to a file on disk
  class War
    DEFAULT_MANIFEST = %{Manifest-Version: 1.0\nCreated-By: Warbler #{Warbler::VERSION}\n\n}

    attr_reader :files
    attr_reader :webinf_filelist
    attr_reader :mapped_files_to_compile

    def initialize
      @files = {}
      @mapped_files_to_compile = []
    end

    # Apply the information in a Warbler::Config object in order to
    # look for files to put into this war file.
    def apply(config)
      find_webinf_files(config)
      find_java_libs(config)
      find_java_classes(config)
      find_gems_files(config)
      find_public_files(config)
      add_webxml(config)
      add_manifest(config)
      add_bundler_files(config)
    end

    # Create the war file. The single argument can either be a
    # Warbler::Config or a filename of the war file to create.
    def create(config_or_path)
      war_path = config_or_path
      if Warbler::Config === config_or_path
        war_path = "#{config_or_path.war_name}.war"
        war_path = File.join(config_or_path.autodeploy_dir, war_path) if config_or_path.autodeploy_dir
        if config_or_path.use_jrubyc == true
        	puts "Compiling Files"
        	compile_files(config_or_path)
        end
      end
      rm_f war_path
      ensure_directory_entries
      puts "Creating #{war_path}"
      create_war war_path, @files
    end

    # Add web.xml and other WEB-INF configuration files from
    # config.webinf_files to the war file.
    def add_webxml(config)
      config.webinf_files.each do |wf|
        if wf =~ /\.erb$/
          require 'erb'
          erb = ERB.new(File.open(wf) {|f| f.read })
          contents = StringIO.new(erb.result(erb_binding(config.webxml)))
          @files[apply_pathmaps(config, wf, :webinf)] = contents
        else
          @files[apply_pathmaps(config, wf, :webinf)] = wf
        end
      end
    end

    # Add a manifest file either from config or by making a default manifest.
    def add_manifest(config = nil)
      unless @files.keys.detect{|k| k =~ /^META-INF\/MANIFEST\.MF$/i}
        if config && config.manifest_file
          @files['META-INF/MANIFEST.MF'] = config.manifest_file
        else
          @files['META-INF/MANIFEST.MF'] = StringIO.new(DEFAULT_MANIFEST)
        end
      end
    end

    # Add java libraries to WEB-INF/lib.
    def find_java_libs(config)
      config.java_libs.map {|lib| add_with_pathmaps(config, lib, :java_libs) }
    end

    # Add java classes to WEB-INF/classes.
    def find_java_classes(config)
      config.java_classes.map {|f| add_with_pathmaps(config, f, :java_classes) }
    end

    # Add public/static assets to the root of the war file.
    def find_public_files(config)
      config.public_html.map {|f| add_with_pathmaps(config, f, :public_html) }
    end

    # Add gems to WEB-INF/gems
    def find_gems_files(config)
      config.gems.each {|gem, version| find_single_gem_files(config, gem, version) }
    end

    # Add a single gem to WEB-INF/gems
    def find_single_gem_files(config, gem_pattern, version = nil)
      if Gem::Specification === gem_pattern
        spec = gem_pattern
      else
        gem = case gem_pattern
              when Gem::Dependency
                gem_pattern
              else
                Gem::Dependency.new(gem_pattern, Gem::Requirement.create(version))
              end

        # skip development dependencies
        return if gem.respond_to?(:type) and gem.type != :runtime

        matched = Gem.source_index.search(gem)
        fail "gem '#{gem}' not installed" if matched.empty?
        spec = matched.last
      end

      # skip gems with no load path
      return if spec.loaded_from == ""

      add_with_pathmaps(config, spec.loaded_from, :gemspecs)
      spec.files.each do |f|
        src = File.join(spec.full_gem_path, f)
        # some gemspecs may have incorrect file listings
        next unless File.exist?(src)
        @files[apply_pathmaps(config, File.join(spec.full_name, f), :gems)] = src
      end

      spec.dependencies.each {|dep| find_single_gem_files(config, dep) } if config.gem_dependencies
    end

    # Add all application directories and files to WEB-INF.
    def find_webinf_files(config)
      config.dirs.select do |d|
        exists = File.directory?(d)
        warn "warning: application directory `#{d}' does not exist or is not a directory; skipping" unless exists
        exists
      end.each do |d|
        @files[apply_pathmaps(config, d, :application)] = nil
      end
      @webinf_filelist = FileList[*(config.dirs.map{|d| "#{d}/**/*"})]
      @webinf_filelist.include *(config.includes.to_a)
      @webinf_filelist.exclude *(config.excludes.to_a)
      @webinf_filelist.map {|f| add_with_pathmaps(config, f, :application) }
    end

		def compile_files(config)
			if config.use_jrubyc
				if defined?(JRUBY_VERSION) and JRUBY_VERSION >= "1.5"
					FileUtils.mkdir_p(File.join(Dir.pwd, 'tmp', 'warbler', 'build'))
					@mapped_files_to_compile.each do |mapped_name|
						# compile source => target dir
						source = @files[mapped_name]
						target = File.join(Dir.pwd, 'tmp', 'warbler', 'build')
						JRuby::Compiler::compile_files(source, Dir.pwd, '', target)
						
						# Rename the mapping to .class and map it to the compiled file under tmp/warbler/build/**path**.class
						app_path = org.jruby.util.JavaNameMangler.mangle_filename_for_classpath(source, Dir.pwd, "")
						@files.delete(mapped_name)
						@files[mapped_name[0..-3] + "class"] = File.join(target, app_path + ".class")
					end
				else
					puts "WARNING: use_jrubyc is true but you are not running JRUBY_VERSION >= 1.5. Files will not be compiled"
				end
			end
		end

    # Add Bundler Gemfile and .bundle/environment.rb to the war file.
    def add_bundler_files(config)
      if config.bundler
        @files[apply_pathmaps(config, 'Gemfile', :application)] = 'Gemfile'
        if File.exist?('Gemfile.lock')
          @files[apply_pathmaps(config, 'Gemfile.lock', :application)] = 'Gemfile.lock'
          @files[apply_pathmaps(config, '.bundle/environment.rb', :application)] = '.bundle/war-environment.rb'
        end
      end
    end

    private
    def add_with_pathmaps(config, f, map_type)
      pathmap = apply_pathmaps(config, f, map_type)
    	@mapped_files_to_compile << pathmap if map_type == :application and config.use_jrubyc and f =~ /\.rb$/ and !config.jrubyc_exclude.include?(f)
      @files[pathmap] = f
    end

    def erb_binding(webxml)
      binding
    end

    def apply_pathmaps(config, file, pathmaps)
      pathmaps = config.pathmaps.send(pathmaps)
      pathmaps.each do |p|
        file = file.pathmap(p)
      end if pathmaps
      file
    end

    def ensure_directory_entries
      files.select {|k,v| !v.nil? }.each do |k,v|
        dir = File.dirname(k)
        while dir != "." && !files.has_key?(dir)
          files[dir] = nil
          dir = File.dirname(dir)
        end
      end
    end

    def create_war(war_file, entries)
      Zip::ZipFile.open(war_file, Zip::ZipFile::CREATE) do |zipfile|
        entries.keys.sort.each do |entry|
          src = entries[entry]
          if src.respond_to?(:read)
            zipfile.get_output_stream(entry) {|f| f << src.read }
          elsif src.nil? || File.directory?(src)
            warn "directory symlinks are not followed unless using JRuby; #{entry} contents not in archive" \
              if File.symlink?(entry) && !defined?(JRUBY_VERSION)
            zipfile.mkdir(entry)
          elsif File.symlink?(src)
            zipfile.get_output_stream(entry) {|f| f << File.read(src) }
          else
            zipfile.add(entry, src)
          end
        end
      end
    end

    # Java-boosted war creation for JRuby; replaces #create_war with Java version
    require 'warbler_war' if defined?(JRUBY_VERSION) && JRUBY_VERSION >= "1.5"
  end
end
