#
# ronin-fuzzer - A Ruby library for generating, mutating, and fuzzing data.
#
# Copyright (c) 2006-2023 Hal Brodigan (postmodern.mod3 at gmail.com)
#
# This file is part of ronin-fuzzer.
#
# ronin-fuzzer is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ronin-fuzzer is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ronin-fuzzer.  If not, see <https://www.gnu.org/licenses/>.
#

require 'ronin/fuzzer/cli/command'
require 'ronin/core/cli/logging'

require 'ronin/fuzzing/repeater'
require 'ronin/fuzzing/fuzzer'
require 'ronin/fuzzing'

require 'shellwords'
require 'tempfile'
require 'socket'

module Ronin
  module Fuzzer
    class CLI
      module Commands
        #
        # Performs basic fuzzing of files, commands or TCP/UDP services.
        #
        # ## Usage
        #
        #     ronin-fuzzer fuzz [options]
        #
        # ## Options
        #
        #     -v, --[no-]verbose               Enable verbose output.
        #     -q, --[no-]quiet                 Disable verbose output.
        #         --[no-]silent                Silence all output.
        #     -r [[PATTERN|/REGEXP/]:[METHOD|STRING*N[-M]]],
        #         --rule                       Adds a fuzzing rule.
        #     -i, --input [FILE]               Input file to fuzz.
        #     -o, --output [FILE]              Output file path.
        #     -c [PROGRAM [OPTIONS|#string#|#path#] ...],
        #         --command                    Template command to run.
        #     -t, --tcp [HOST:PORT]            TCP service to fuzz.
        #     -u, --udp [HOST:PORT]            UDP service to fuzz.
        #     -p, --pause [SECONDS]            Pause in between mutations.
        #
        # ## Examples
        #
        #     ronin-fuzzer fuzz -i request.txt -r unix_path:bad_strings -o bad.txt
        #
        class Fuzz < Command

          include Core::CLI::Logging

          option :input, short: '-i',
                         value: {
                           type:  String,
                           usage: 'FILE'
                         },
                         desc: 'Input file to fuzz'

          option :rules, short: '-r',
                         value: {
                           type:  String,
                           usage: '[PATTERN|/REGEXP/|STRING]:[METHOD|STRING*N[-M]]'
                         },
                         desc: 'Adds a fuzzing rule' do |value|
                           @rules << parse_rule(value)
                         end

          option :output, short: '-o',
                          value: {
                            type:  String,
                            usage: 'PATH'
                          },
                          desc: 'Output file path'

          option :command, short: '-c',
                           value: {
                             type:  String,
                             usage: '"PROGRAM [OPTIONS|#string#|#path#] ..."'
                           },
                           desc: 'Template command to run'

          option :tcp, short: '-t',
                       value: {
                         type:  String,
                         usage: 'HOST:PORT'
                       },
                       desc: 'TCP service to fuzz'

          option :udp, short: '-u',
                       value: {
                         type:  String,
                         usage: 'HOST:PORT'
                       },
                       desc: 'UDP service to fuzz'

          option :pause, short: '-p',
                         value: {
                           type:  Float,
                           usage: 'SECONDS'
                         },
                         desc: 'Pause in between mutations'

          description 'Performs basic fuzzing of files'

          examples [
            "-i request.txt -o bad.txt -r unix_path:bad_strings"
          ]

          man_page 'ronin-fuzzer-fuzz.1'

          # The fuzzing rules.
          #
          # @return [Array<(Regexp, Enumerator)>]
          attr_reader :rules

          #
          # Initializes the `ronin-fuzzer fuzz` command.
          #
          # @param [Hash{Symbol => Object}] kwargs
          #   Additional keyword arguments.
          #
          def initialize(**kwargs)
            super(**kwargs)

            @rules = []
          end

          #
          # Sets up the fuzz command.
          #
          def run
            if @rules.empty?
              print_error "Must specify at least one fuzzing rule"
              exit(-1)
            end

            if options[:output]
              @output    = options[:output]
              @file_ext  = File.extname(@output)
              @file_name = @output.chomp(@file_ext)
            elsif options[:command]
              @command = shellwords(options[:command])
            elsif (options[:tcp] || options[:udp])
              @socket_class = if    options[:tcp] then TCPSocket
                              elsif options[:udp] then UDPSocket
                              end

              @host, @port = (options[:tcp] || options[:udp]).split(':',2)
              @port = @port.to_i
            end

            data   = if options[:input] then File.read(options[:input])
                     else                    $stdin.read
                     end

            method = if options[:output]
                       method(:fuzz_file)
                     elsif options[:command]
                       method(:fuzz_command)
                     elsif (options[:tcp] || options[:udp])
                       method(:fuzz_network)
                     else
                       method(:print_fuzz)
                     end

            fuzzer = Fuzzing::Fuzzer.new(@rules)
            fuzzer.each(data).each_with_index do |string,index|
              method.call(string,index + 1)

              sleep(options[:pause]) if options[:pause]
            end
          end

          private

          include Shellwords

          #
          # Writes the fuzzed string to a file.
          #
          # @param [String] string
          #   The fuzzed string.
          #
          # @param [Integer] index
          #   The iteration number.
          #
          def fuzz_file(string,index)
            path = "#{@file_name}-#{index}#{@file_ext}"

            log_info "Creating file ##{index}: #{path} ..."

            File.open(path,'wb') do |file|
              file.write string
            end
          end

          #
          # Runs the fuzzed string in a command.
          #
          # @param [String] string
          #   The fuzzed string.
          #
          # @param [Integer] index
          #   The iteration number.
          #
          def fuzz_command(string,index)
            Tempfile.open("ronin-fuzzer-#{index}") do |tempfile|
              tempfile.write(string)
              tempfile.flush

              arguments = @command.map do |argument|
                if argument.include?('#path#')
                  argument.sub('#path#',tempfile.path)
                elsif argument.include?('#string#')
                  argument.sub('#string#',string)
                else
                  argument
                end
              end

              log_info "Running command #{index}: #{arguments.join(' ')} ..."

              # run the command as it's own process
              unless system(*arguments)
                status = $?

                if status.coredump?
                  # jack pot!
                  log_error "Process ##{status.pid} coredumped!"
                else
                  # process errored out
                  log_warning "Process ##{status.pid} exited with status #{status.exitstatus}"
                end
              end
            end
          end

          #
          # Sends the fuzzed string to a TCP/UDP Service.
          #
          # @param [String] string
          #   The fuzzed string.
          #
          # @param [Integer] index
          #   The iteration number.
          #
          def fuzz_network(string,index)
            log_debug "Connecting to #{@host}:#{@port} ..."
            socket = @socket_class.new(@host,@port)

            log_info "Sending message ##{index}: #{string.inspect} ..."
            socket.write(string)
            socket.flush

            log_debug "Disconnecting from #{@host}:#{@port} ..."
            socket.close
          end

          #
          # Prints the fuzzed string to STDOUT.
          #
          # @param [String] string
          #   The fuzzed string.
          #
          # @param [Integer] index
          #   The iteration number.
          #
          def print_fuzz(string,index)
            log_debug "String ##{index} ..."

            puts string
          end

          #
          # Parses a fuzzing rule.
          #
          # @param [String] string
          #   The fuzzing rule.
          #
          # @eturn [(Regexp, Enumerator)]
          #   The fuzzing pattern and list of substitutions.
          #
          def parse_rule(value)
            if value.start_with?('/')
              unless (index = value.rindex('/:'))
                raise(OptionParser::InvalidArgument,"argument must be of the form /REGEXP/:REPLACE, but was: #{value}")
              end

              regexp       = parse_pattern(value[1...index])
              substitution = parse_substitution(value[index+2..])

              return [regexp, substitution]
            else
              unless (index = value.rindex(':'))
                raise(OptionParser::InvalidArgument,"argument must be of the form STRING:STYLE but was: #{value}")
              end

              pattern      = parse_pattern(value[0...index])
              substitution = parse_substitution(value[index+1..])

              return [pattern, substitution]
            end
          end

          #
          # Parses a fuzz pattern.
          #
          # @param [String] string
          #   The string to parse.
          #
          # @return [Regexp, String]
          #   The parsed pattern.
          #
          def parse_pattern(string)
            case string
            when /^\/.+\/$/
              Regexp.new(string[1..-2])
            when /^[a-z][a-z_]+$/
              const = string.upcase

              if (Regexp.const_defined?(const) &&
                  Regexp.const_get(const).kind_of?(Regexp))
                Regexp.const_get(const)
              else
                string
              end
            else
              string
            end
          end

          #
          # Parses a fuzz substitution Enumerator.
          #
          # @param [String] string
          #   The string to parse.
          #
          # @return [Enumerator]
          #   The parsed substitution Enumerator.
          #
          def parse_substitution(string)
            if string.include?('*')
              string, lengths = string.split('*',2)

              lengths = if lengths.include?('-')
                          min, max = lengths.split('-',2)

                          (min.to_i .. max.to_i)
                        else
                          lengths.to_i
                        end

              Fuzzing::Repeater.new(lengths).each(string)
            else
              Fuzzing[string]
            end
          end

        end
      end
    end
  end
end
