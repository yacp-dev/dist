#!/usr/bin/env bash
# Rebuilds shared-mime-info's /usr/share/mime/mime.cache after the extra
# dependencies are installed. Its postinstall (zp_shared-mime-info.sh,
# `update-mime-database -n /usr/share/mime`) has been seen to exit 1
# inside cygwin-install-action -- "abnormal exit: exit code=1", with the
# install step still reported as a success -- leaving no mime.cache.
# GIO's g_content_type_guess then can't tell any file type apart, and
# gdk-pixbuf (2.36, which sniffs formats through it) fails every image:
# eid-mw 5.1.31's `gdk-pixbuf-csource` on a plain JPEG gave "Couldn't
# recognize the image file format", with the JPEG loader in loaders.cache.
#
# Runs without -n so the cache is rebuilt even if a stale one exists, and
# lets update-mime-database's own output through, since the postinstall's
# was swallowed. A failure here is a warning, not an error: most packages
# never sniff MIME types, and those that do fail later with their own log.
set -u

if [ ! -x /usr/bin/update-mime-database ]; then
	echo "shared-mime-info not installed -- nothing to refresh"
	exit 0
fi

if /usr/bin/update-mime-database /usr/share/mime; then
	ls -l /usr/share/mime/mime.cache
else
	echo "::warning title=update-mime-database failed::update-mime-database /usr/share/mime exited $? -- MIME type sniffing (GIO, gdk-pixbuf) may not work"
fi
exit 0
