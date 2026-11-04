# frozen_string_literal: true

# Keeps `xezat bump` from demanding halibut for packages that merely ship
# Halibut *sources*.
#
# xezat's Halibut detector (lib/xezat/detector/halibut.rb) reports halibut as
# a build requirement as soon as any `.but` file exists under the source
# tree -- the files are documentation sources, and a package that ships the
# documentation already built (apt-cacher-ng: doc/README, doc/*.pdf and
# doc/html/ are in the tarball, and its CMake build only installs them) never
# runs halibut. Bump then turns that detection into a development package to
# resolve against installed.db, and on the runner the lookup fails ("Package
# halibut is not installed"), so the README is never rewritten.
#
# A recipe that does build its documentation with halibut lists it in
# BUILD_REQUIRES (spigot does), so the detection is only dropped when the
# recipe doesn't ask for it -- keeping it there would make the README name a
# tool the build never uses. Nothing else in xezat reads the tool list.
#
# Loaded via RUBYOPT=-r<this file> by scripts/xezat_bump.sh, for that one
# `xezat bump` invocation only, so prep/validate/port keep their own
# detection. Preloads before xezat's own requires; `require 'xezat/detectors'`
# here resolves the installed gem the same way scripts/bashvar_diagnostic_patch.rb
# resolves bashvar.
require 'xezat/detectors'

module Xezat
  module SkipHalibutDetector
    def detect(variables)
      tools = super
      requires = variables[:BUILD_REQUIRES].to_s.split.map(&:to_sym)
      tools.delete(:halibut) unless requires.include?(:halibut)
      tools
    end
  end

  DetectorManager.prepend(SkipHalibutDetector)
end
