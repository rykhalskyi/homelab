# Custom Nextcloud image: the official image plus the BookTailor and
# Bye Bye Money List apps.
#
# Built by .github/workflows/build-nextcloud-image.yml from the pinned release
# tarballs (BYML_VERSION / BOOKTAILOR_VERSION and their SHA256 values in
# versions.env). The workflow downloads, checksum-verifies and extracts those
# tarballs into the build context as ./byebyemoneylist/ and ./booktailor/, so no
# frontend build happens here: the release tarballs already contain the
# compiled js/ and css/ (both are gitignored in the app repos, which is why we
# build from the artifacts and not from a git checkout).
#
# The apps are kept OUTSIDE /var/www/html so the persistent PVC never shadows
# them; the HelmRelease `before-starting` hook copies /opt/<app> into
# /var/www/html/custom_apps/<app> on every boot.
ARG NEXTCLOUD_VERSION=31-apache
FROM nextcloud:${NEXTCLOUD_VERSION}

COPY byebyemoneylist /opt/byebyemoneylist
COPY booktailor /opt/booktailor
RUN chown -R www-data:www-data /opt/byebyemoneylist /opt/booktailor
