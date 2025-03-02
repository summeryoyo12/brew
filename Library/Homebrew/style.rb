# frozen_string_literal: true

module Homebrew
  # Helper module for running RuboCop.
  #
  # @api private
  module Style
    module_function

    # Checks style for a list of files, printing simple RuboCop output.
    # Returns true if violations were found, false otherwise.
    def check_style_and_print(files, **options)
      check_style_impl(files, :print, **options)
    end

    # Checks style for a list of files, returning results as a RubocopResults
    # object parsed from its JSON output.
    def check_style_json(files, **options)
      check_style_impl(files, :json, **options)
    end

    def check_style_impl(files, output_type,
                         fix: false, except_cops: nil, only_cops: nil, display_cop_names: false,
                         debug: false, verbose: false)
      Homebrew.install_bundler_gems!
      require "rubocop"
      require "rubocops"

      args = %w[
        --force-exclusion
      ]
      args << if fix
        "--auto-correct"
      else
        "--parallel"
      end

      args += ["--extra-details"] if verbose
      args += ["--display-cop-names"] if display_cop_names || verbose

      if except_cops
        except_cops.map! { |cop| RuboCop::Cop::Cop.registry.qualified_cop_name(cop.to_s, "") }
        cops_to_exclude = except_cops.select do |cop|
          RuboCop::Cop::Cop.registry.names.include?(cop) ||
            RuboCop::Cop::Cop.registry.departments.include?(cop.to_sym)
        end

        args << "--except" << cops_to_exclude.join(",") unless cops_to_exclude.empty?
      elsif only_cops
        only_cops.map! { |cop| RuboCop::Cop::Cop.registry.qualified_cop_name(cop.to_s, "") }
        cops_to_include = only_cops.select do |cop|
          RuboCop::Cop::Cop.registry.names.include?(cop) ||
            RuboCop::Cop::Cop.registry.departments.include?(cop.to_sym)
        end

        odie "RuboCops #{only_cops.join(",")} were not found" if cops_to_include.empty?

        args << "--only" << cops_to_include.join(",")
      end

      has_non_formula = Array(files).any? do |file|
        File.expand_path(file).start_with? HOMEBREW_LIBRARY_PATH
      end

      if files.present? && !has_non_formula
        config = if files.first && File.exist?("#{files.first}/spec")
          HOMEBREW_LIBRARY/".rubocop_rspec.yml"
        else
          HOMEBREW_LIBRARY/".rubocop.yml"
        end
        args << "--config" << config
      end

      if files.blank?
        args << HOMEBREW_LIBRARY_PATH
      else
        args += files
      end

      cache_env = { "XDG_CACHE_HOME" => "#{HOMEBREW_CACHE}/style" }

      rubocop_success = false

      case output_type
      when :print
        args << "--debug" if debug
        args << "--format" << "simple" if files.present?
        system(cache_env, "rubocop", *args)
        rubocop_success = $CHILD_STATUS.success?
      when :json
        json, err, status =
          Open3.capture3(cache_env, "rubocop", "--format", "json", *args)
        # exit status of 1 just means violations were found; other numbers mean
        # execution errors.
        # exitstatus can also be nil if RuboCop process crashes, e.g. due to
        # native extension problems.
        # JSON needs to be at least 2 characters.
        if !(0..1).cover?(status.exitstatus) || json.to_s.length < 2
          raise "Error running `rubocop --format json #{args.join " "}`\n#{err}"
        end

        return RubocopResults.new(JSON.parse(json))
      else
        raise "Invalid output_type for check_style_impl: #{output_type}"
      end

      return rubocop_success if files.present?

      shellcheck   = which("shellcheck")
      shellcheck ||= which("shellcheck", ENV["HOMEBREW_PATH"])
      shellcheck ||= begin
        ohai "Installing `shellcheck` for shell style checks..."
        system HOMEBREW_BREW_FILE, "install", "shellcheck"
        which("shellcheck") || which("shellcheck", ENV["HOMEBREW_PATH"])
      end
      unless shellcheck
        opoo "Could not find or install `shellcheck`! Not checking shell style."
        return rubocop_success
      end

      shell_files = [
        HOMEBREW_BREW_FILE,
        *Pathname.glob("#{HOMEBREW_LIBRARY}/Homebrew/*.sh"),
        *Pathname.glob("#{HOMEBREW_LIBRARY}/Homebrew/cmd/*.sh"),
        *Pathname.glob("#{HOMEBREW_LIBRARY}/Homebrew/utils/*.sh"),
      ].select(&:exist?)
      # TODO: check, fix completions here too.
      # TODO: consider using ShellCheck JSON output
      shellcheck_success = system shellcheck, "--shell=bash", *shell_files
      rubocop_success && shellcheck_success
    end

    # Result of a RuboCop run.
    class RubocopResults
      def initialize(json)
        @metadata = json["metadata"]
        @file_offenses = {}
        json["files"].each do |f|
          next if f["offenses"].empty?

          file = File.realpath(f["path"])
          @file_offenses[file] = f["offenses"].map { |x| RubocopOffense.new(x) }
        end
      end

      def file_offenses(path)
        @file_offenses.fetch(path.to_s, [])
      end
    end

    # A RuboCop offense.
    class RubocopOffense
      attr_reader :severity, :message, :corrected, :location, :cop_name

      def initialize(json)
        @severity = json["severity"]
        @message = json["message"]
        @cop_name = json["cop_name"]
        @corrected = json["corrected"]
        @location = RubocopLineLocation.new(json["location"])
      end

      def severity_code
        @severity[0].upcase
      end

      def corrected?
        @corrected
      end

      def correction_status
        "[Corrected] " if corrected?
      end

      def to_s(display_cop_name: false)
        if display_cop_name
          "#{severity_code}: #{location.to_short_s}: #{cop_name}: " \
          "#{Tty.green}#{correction_status}#{Tty.reset}#{message}"
        else
          "#{severity_code}: #{location.to_short_s}: #{Tty.green}#{correction_status}#{Tty.reset}#{message}"
        end
      end
    end

    # Source location of a RuboCop offense.
    class RubocopLineLocation
      attr_reader :line, :column, :length

      def initialize(json)
        @line = json["line"]
        @column = json["column"]
        @length = json["length"]
      end

      def to_s
        "#{line}: col #{column} (#{length} chars)"
      end

      def to_short_s
        "#{line}: col #{column}"
      end
    end
  end
end
