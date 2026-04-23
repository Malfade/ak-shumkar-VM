# Patched gvmd: composite scanner types 11 (OpenVAS+CVE) and 12 (OpenVASd+CVE).
# Build from repository root:
#   docker build -f docker/gvmd-patched.Dockerfile -t ak-shumkar-gvmd:local .
#
# Requires network for apt and matches gvm-libs stack from Greenbone.
FROM ghcr.io/greenbone/gvm-libs:stable AS builder
ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /build
COPY third_party/gvmd /build/gvmd
RUN apt-get update \
  && apt-get install -y --no-install-recommends --no-install-suggests \
       $(grep -v '^#' /build/gvmd/.github/build-dependencies.list | xargs) \
  && mkdir -p /build/gvmd/build \
  && cd /build/gvmd/build \
  && cmake .. -DCMAKE_INSTALL_PREFIX=/usr \
  && cmake --build . -j"$(nproc)" \
  && DESTDIR=/staging cmake --install .

FROM registry.community.greenbone.net/community/gvmd:stable
COPY --from=builder /staging/usr/sbin/gvmd /usr/sbin/gvmd
COPY --from=builder /staging/usr/sbin/gvmd /usr/local/sbin/gvmd
