# frozen_string_literal: true

# Works around (and diagnoses) BashVar.parse crashing outright on a
# single invalid UTF-8 byte anywhere in cygport's `bashvar` dump
# (compgen -v | declare -p every shell variable -- see xezat's own
# share/xezat/bashvar.sh) -- BashVar.parse's very first line calls
# .strip on the WHOLE blob (bashvar's lib/bashvar.rb:8), so one bad
# byte in ANY variable (this dumps every shell variable in scope, not
# just this package's own cygport ones -- confirmed against a real
# failure and against the committed cygport file itself decoding as
# clean UTF-8, ruling out the package's own content) kills parsing
# entirely, with xezat prep at the time (and xezat bump/port, which
# call Xezat#variables too) aborting with no indication of which
# variable or why.
#
# Deliberately never logs variable VALUES, only names/byte positions --
# this repo's CI logs are public (yacp-dev/dist, yacp-dev/ports), and
# `compgen -v` can pick up ambient runner-injected tokens (e.g.
# ACTIONS_RUNTIME_TOKEN) that GitHub Actions' own secret-masking isn't
# guaranteed to cover, since masking is keyed off exact known `secrets.*`
# values, not every ambient env var a third-party action might set.
#
# Loaded via RUBYOPT=-r<this file> (build-package.yml), which preloads
# before xezat's own `require 'bashvar'` -- reopening the class here
# still takes effect regardless of require order, since a later
# `require 'bashvar'` is then just a no-op against the already-loaded
# (and now patched) class.
require 'bashvar'

class BashVar
  class << self
    alias_method :__dorgann_original_parse, :parse

    def parse(input, **kwargs)
      return __dorgann_original_parse(input, **kwargs) if input.nil? || input.valid_encoding?

      warn "bashvar_diagnostic_patch.rb: invalid UTF-8 in the bashvar dump -- " \
           "scrubbing per offending line (names/byte positions only, never values):"

      cleaned = input.b.each_line.map do |line|
        line.force_encoding(Encoding::UTF_8)
        next line if line.valid_encoding?

        raw = line.b
        name = raw[/\Adeclare\s+(?:-\S+\s+)?([A-Za-z_][A-Za-z0-9_]*)=/, 1] || '(unparseable declare -p line)'
        first_bad = raw.each_byte.with_index.find { |byte, _| byte >= 0x80 }&.last
        warn "  #{name}: #{raw.bytesize} bytes, first non-ASCII byte at offset #{first_bad.inspect}"

        line.scrub.force_encoding(Encoding::UTF_8)
      end.join
      cleaned.force_encoding(Encoding::UTF_8)

      __dorgann_original_parse(cleaned, **kwargs)
    end
  end
end
