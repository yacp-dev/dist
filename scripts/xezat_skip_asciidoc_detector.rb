# frozen_string_literal: true

# Keeps `xezat bump` from listing asciidoc as a build requirement.
#
# xezat's Asciidoc detector (xezat-0.6.0's lib/xezat/detector/asciidoc.rb)
# reports a package as using asciidoc as soon as any configure.ac under the
# source tree mentions the word "asciidoc" -- even when the build leaves docs
# off (czmq-4.2.1: `--with-docs=(yes|no)`, and the recipe passes
# `--without-docs`). Bump then turns that detection into a development
# package to resolve against installed.db, and on the runner that lookup
# fails ("Package asciidoc is not installed"), so the README is never
# rewritten. Dropping the result after detection is enough: nothing else
# in xezat reads the tool list.
#
# Loaded via RUBYOPT=-r<this file> by scripts/xezat_bump.sh, for that one
# `xezat bump` invocation only, so prep/validate/port keep their own
# detection. Preloads before xezat's own requires; `require 'xezat/detectors'`
# here resolves the installed gem the same way scripts/bashvar_diagnostic_patch.rb
# resolves bashvar.
require 'xezat/detectors'

module Xezat
  module SkipAsciidocDetector
    def detect(variables)
      tools = super
      tools.delete(:asciidoc)
      tools
    end
  end

  DetectorManager.prepend(SkipAsciidocDetector)
end
