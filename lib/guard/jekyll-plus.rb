# encoding: UTF-8

require 'benchmark'
require 'guard/plugin'
require 'jekyll'
require 'pathname'

begin
  require 'rack'
rescue LoadError
end

module Guard
  class Jekyllplus < Plugin
    EXTS = %w(md mkd mkdn markdown textile html haml slim xml yml sass scss)

    def initialize(options = {})
      super

      @options = {
        extensions: [],
        config: ['_config.yml'],
        serve: false,
        rack_config: nil,
        drafts: false,
        future: false,
        config_hash: nil,
        silent: false,
        msg_prefix: 'Jekyll'
      }.merge(options)

      @config = load_config(@options)
      @source = local_path @config['source']
      @destination = local_path @config['destination']
      @msg_prefix = @options[:msg_prefix]

      # Convert array of extensions into a regex for matching file extensions
      # eg, /\.md$|\.markdown$|\.html$/i
      #
      extensions  = @options[:extensions].concat(EXTS).flatten.uniq
      extensions.map! { |e| "#{e}$".gsub('\.', '\\.') }
      @extensions = Regexp.new(extensions.join('|'), true)

      # set Jekyll server thread to nil
      @server_thread = nil
    end

    def load_config(options)
      config = jekyll_config(options)

      # Override configuration with guard option values
      config['show_drafts'] ||= options[:drafts]
      config['future']      ||= options[:future]
      config
    end

    def reload_config!
      UI.info 'Reloading Jekyll configuration!'
      @config = load_config(@options)
    end

    def start
      if @options[:serve]
        build
        start_server
        unless silent?
          msg = '%s watching and serving at %s:%s%s'
          UI.info format(msg, @msg_prefix, @config['host'], @config['baseurl'])
        end
      else
        build
        UI.info "#{@msg_prefix} " + 'watching' unless silent?
      end
    end

    def reload
      stop if !@server_thread.nil? && @server_thread.alive?
      reload_config!
      start
    end

    def reload_server
      stop_server
      start_server
    end

    def stop
      stop_server
    end

    def run_on_modifications(paths)
      # At this point we know @options[:config] is going to be an Array
      # thanks to the call the jekyll_config earlier.
      reload_config! if @options[:config].map { |f| paths.include?(f) }.any?
      matched = jekyll_matches paths
      unmatched = non_jekyll_matches paths
      if matched.size > 0
        build(matched, 'Files changed: ', '  ~ '.yellow)
      elsif unmatched.size > 0
        copy(unmatched)
      end
    end

    def run_on_additions(paths)
      matched = jekyll_matches paths
      unmatched = non_jekyll_matches paths

      if matched.size > 0
        build(matched, 'Files added: ', '  + '.green)
      elsif unmatched.size > 0
        copy(unmatched)
      end
    end

    def run_on_removals(paths)
      matched = jekyll_matches paths
      unmatched = non_jekyll_matches paths

      if matched.size > 0
        build(matched, 'Files removed: ', '  x '.red)
      elsif unmatched.size > 0
        remove(unmatched)
      end
    end

    private

    def silent?
      # TODO: use hash with indifferent access
      @config[:silent] || @config['silent']
    end

    def build(files = nil, message = '', mark = nil)
      UI.info "#{@msg_prefix} #{message}" + 'building...'.yellow unless silent?
      if files
        puts '| ' # spacing
        files.each { |file| puts '|' + mark + file }
        puts '| ' # spacing
      end

      elapsed = Benchmark.realtime { build_site(@config) }

      unless silent?
        fmt = '%s build completed in %ss '.green + '%s → %s'
        msg = format(fmt, @msg_prefix, elapsed.round(2), @source, @destination)
        UI.info msg
      end

    rescue RuntimeError => e
      UI.error "#{@msg_prefix} build has failed" unless silent?
      UI.error e.to_s
      stop_server
      throw :task_has_failed
    end

    # Copy static files to destination directory
    #
    def copy(files = [])
      files = ignore_stitch_sources files
      return if files.empty?

      message = 'copied file'
      message += 's' if files.size > 1
      UI.info "#{@msg_prefix} #{message.green}" unless silent?
      puts '| ' # spacing

      files.each do |file|
        if(!check_jekyll_exclude(file))
          path = destination_path file
          FileUtils.mkdir_p File.dirname(path)
          FileUtils.cp file, path
          puts '|' + '  → '.green + path
        else
          puts '|' + '  ~ '.yellow + "Jekyll exclude: Ignoring changes to #{file}".yellow
        end
      end
      puts '| ' # spacing
      true

    rescue StandardError => e
      UI.error "#{@msg_prefix} copy has failed" unless silent?
      UI.error e
      stop_server
      throw :task_has_failed
    end

    def ignore_stitch_sources(files)
      if ENV['GUARD_STITCH_PLUS_FILES']
        ignore = ENV['GUARD_STITCH_PLUS_FILES'].split(',')
        files.reject { |f| ignore.include? f }
      else
        files
      end
    end

    # Remove deleted source file/directories from destination
    #
    def remove(files = [])
      files = ignore_stitch_sources files
      # Ensure at least one file still exists (other scripts may clean up too)

      return if files.none? { |f| File.exist?(f) }

      message = 'removed file'
      message += 's' if files.size > 1
      UI.info "#{@msg_prefix} #{message.red}" unless silent?
      puts '| ' # spacing

      files.each do |file|
        path = destination_path file
        if File.exist? path
          FileUtils.rm path
          puts '|' + '  x '.red + path
        end

        dir = File.dirname path
        if Dir[dir + '/*'].empty?
          FileUtils.rm_r(dir)
          puts '|' + '  x '.red + dir
        end
      end
      puts '| ' # spacing
      true

    rescue StandardError => e
      UI.error "#{@msg_prefix} remove has failed" unless silent?
      UI.error e
      stop_server
      throw :task_has_failed
    end

    def jekyll_matches(paths)
      paths.select { |file| file =~ @extensions }
    end

    def non_jekyll_matches(paths)
      paths.select { |file| !file.match(/^_/) && !file.match(@extensions) }
    end

    def jekyll_config(options)
      if options[:config_hash]
        config = options[:config_hash]
      elsif options[:config]
        unless options[:config].is_a? Array
          options[:config] = [options[:config]]
        end
        config = options
      end
      Jekyll.configuration(config)
    end

    def check_jekyll_exclude(path)
      return @config['exclude'].any? {|f| File.fnmatch?(path, f)}
    end

    def rack_config(root)
      ENV['RACK_ROOT'] = root
      config_ru = Pathname(__FILE__).expand_path.dirname + '../rack/config.ru'
      default_config = config_ru.to_s
      local_config = File.exist?('config.ru') ? 'config.ru' : nil

      config = (@config['rack_config'] || local_config || default_config)
      {
        config: config,
        Port: @config['port'],
        Host: @config['host'],
        environment: 'development'
      }
    end

    def local_path(path)
      Dir.chdir('.')
      current = Dir.pwd
      path = path.sub current, ''
      if path == ''
        './'
      else
        path.sub(/^\//, '')
      end
    end

    def build_site(options)
      Jekyll.logger.log_level = :error
      site = Jekyll::Site.new(options)
      Jekyll.logger.log_level = :info
      site.process
    end

    def destination_path(file)
      if @source =~ /^\./
        File.join @destination, file
      else
        file.sub(/^#{@source}/, "#{@destination}")
      end
    end

    def server(config)
      if defined? ::Rack
        Thread.new { ::Rack::Server.start(rack_config(@destination)) }
        UI.info "#{@msg_prefix} running Rack" unless silent?
      else
        Thread.new { Jekyll::Commands::Serve.process(config) }
      end
    end

    def start_server
      if @server_thread.nil?
        @server_thread = server(@config)
      else
        UI.warning "#{@msg_prefix} using an old server thread!"
      end
    end

    def stop_server
      @server_thread.kill unless @server_thread.nil?
      @server_thread = nil
    end
  end
end
