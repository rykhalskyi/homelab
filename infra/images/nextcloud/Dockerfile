# Custom Nextcloud image: the official image plus the byebyemoneylist app.
#
# Built by .github/workflows/build-nextcloud-image.yml from the pinned release
# tarball (BYML_VERSION / BYML_SHA256 in versions.env). The workflow downloads,
# checksum-verifies and extracts that tarball into the build context as
# ./byebyemoneylist/, so no frontend build happens here: the release tarball
# already contains the compiled js/ and css/ (both are gitignored in the app
# repo, which is why we build from the artifact and not from a git checkout).
#
# The app is kept OUTSIDE /var/www/html so the persistent PVC never shadows it;
# the HelmRelease `before-starting` hook copies /opt/byebyemoneylist into
# /var/www/html/custom_apps/byebyemoneylist on every boot.
ARG NEXTCLOUD_VERSION=31-apache
FROM nextcloud:${NEXTCLOUD_VERSION}

COPY byebyemoneylist /opt/byebyemoneylist
RUN chown -R www-data:www-data /opt/byebyemoneylist
