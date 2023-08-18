# © Copyright IBM Corporation 2015, 2023
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BASE_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal
ARG BASE_TAG=8.8-1014
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi8/go-toolset
ARG BUILDER_TAG=1.19.10-3
ARG GO_WORKDIR=/opt/app-root/src/go/src/github.com/ibm-messaging/mq-container
ARG MQ_ARCHIVE="downloads/9.3.3.0-IBM-MQ-Advanced-for-Developers-Non-Install-LinuxX64.tar.gz"

###############################################################################
# Build stage to build Go code
###############################################################################
FROM $BUILDER_IMAGE:$BUILDER_TAG as builder
ARG IMAGE_REVISION="Not specified"
ARG IMAGE_SOURCE="Not specified"
ARG IMAGE_TAG="Not specified"
ARG GO_WORKDIR
ARG MQ_ARCHIVE
USER 0
WORKDIR $GO_WORKDIR/
ADD $MQ_ARCHIVE /opt/mqm
ENV CGO_CFLAGS="-I/opt/mqm/inc/" \
    CGO_LDFLAGS_ALLOW="-Wl,-rpath.*" \
    PATH="${PATH}:/opt/mqm/bin"
COPY go.mod go.sum ./
COPY cmd/ ./cmd
COPY internal/ ./internal
COPY pkg/ ./pkg
COPY vendor/ ./vendor
RUN go build -ldflags "-X \"main.ImageCreated=$(date --iso-8601=seconds)\" -X \"main.ImageRevision=$IMAGE_REVISION\" -X \"main.ImageSource=$IMAGE_SOURCE\" -X \"main.ImageTag=$IMAGE_TAG\"" ./cmd/runmqserver/ \
  && go build ./cmd/chkmqready/ \
  && go build ./cmd/chkmqhealthy/ \
  && go build ./cmd/chkmqstarted/ \
  && go build ./cmd/runmqdevserver/ \
  && go test -v ./cmd/runmqdevserver/... \
  && go test -v ./cmd/runmqserver/ \
  && go test -v ./cmd/chkmqready/ \
  && go test -v ./cmd/chkmqhealthy/ \
  && go test -v ./cmd/chkmqstarted/ \
  && go test -v ./pkg/... \
  && go test -v ./internal/... \
  && go vet ./cmd/... ./internal/...

###############################################################################
# Build stage to reduce MQ packages included using genmqpkg
###############################################################################
FROM $BASE_IMAGE:$BASE_TAG AS mq-redux
ARG BASE_IMAGE
ARG BASE_TAG
ARG MQ_ARCHIVE
WORKDIR /tmp/mq
ENV genmqpkg_inc32=0 \
    genmqpkg_incadm=1 \
    genmqpkg_incamqp=0 \
    genmqpkg_incams=1 \
    genmqpkg_inccbl=0 \
    genmqpkg_inccics=0 \
    genmqpkg_inccpp=0 \
    genmqpkg_incdnet=0 \
    genmqpkg_incjava=1 \
    genmqpkg_incjre=1 \
    genmqpkg_incman=0 \
    genmqpkg_incmqbc=0 \
    genmqpkg_incmqft=0 \
    genmqpkg_incmqsf=0 \
    genmqpkg_incmqxr=0 \
    genmqpkg_incnls=1 \
    genmqpkg_incras=1 \
    genmqpkg_incsamp=1 \
    genmqpkg_incsdk=0 \
    genmqpkg_inctls=1 \
    genmqpkg_incunthrd=0 \
    genmqpkg_incweb=1
ADD $MQ_ARCHIVE /opt/mqm-noinstall
# Run genmqpkg to reduce the MQ packages included
RUN /opt/mqm-noinstall/bin/genmqpkg.sh -b /opt/mqm-redux

###############################################################################
# Main build stage, to build MQ image
###############################################################################
FROM $BASE_IMAGE:$BASE_TAG AS mq-server
ARG MQ_URL
ARG BASE_IMAGE
ARG BASE_TAG
ARG GO_WORKDIR
LABEL summary="IBM MQ Advanced Server" \
      description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises" \
      vendor="IBM" \
      maintainer="IBM" \
      distribution-scope="private" \
      authoritative-source-url="https://www.ibm.com/software/passportadvantage/" \
      url="https://www.ibm.com/products/mq/advanced" \
      io.openshift.tags="mq messaging" \
      io.k8s.display-name="IBM MQ Advanced Server" \
      io.k8s.description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises" \
      base-image=$BASE_IMAGE \
      base-image-release=$BASE_TAG
COPY --from=mq-redux /opt/mqm-redux/ /opt/mqm/
COPY setup-image.sh /usr/local/bin/
COPY install-mq-server-prereqs.sh /usr/local/bin/
RUN env \
  && chmod u+x /usr/local/bin/install-*.sh \
  && chmod u+x /usr/local/bin/setup-image.sh \
  && install-mq-server-prereqs.sh \
  && setup-image.sh \
  && /opt/mqm/bin/security/amqpamcf \
  && chown -R 1001:root /opt/mqm/*
COPY --from=builder $GO_WORKDIR/runmqserver /usr/local/bin/
COPY --from=builder $GO_WORKDIR/chkmq* /usr/local/bin/
COPY NOTICES.txt /opt/mqm/licenses/notices-container.txt
COPY ha/native-ha.ini.tpl /etc/mqm/native-ha.ini.tpl
# Copy web XML files
COPY web /etc/mqm/web
COPY etc/mqm/*.tpl /etc/mqm/
RUN chmod ug+x /usr/local/bin/runmqserver \
  && chown 1001:root /usr/local/bin/*mq* \
  && chmod ug+x /usr/local/bin/chkmq* \
  && chown -R 1001:root /etc/mqm/* \
  && install --directory --mode 2775 --owner 1001 --group root /run/runmqserver \
  && touch /run/termination-log \
  && chown 1001:root /run/termination-log \
  && chmod 0660 /run/termination-log \
  && chmod -R g+w /etc/mqm/web
# Always use port 1414 for MQ & 9157 for the metrics
EXPOSE 1414 9157 9443
ENV MQ_OVERRIDE_DATA_PATH=/mnt/mqm/data MQ_OVERRIDE_INSTALLATION_NAME=Installation1 MQ_USER_NAME="mqm" PATH="${PATH}:/opt/mqm/bin"
ENV MQ_GRACE_PERIOD=30
ENV LANG=en_US.UTF-8 AMQ_DIAGNOSTIC_MSG_SEVERITY=1 AMQ_ADDITIONAL_JSON_LOG=1
ENV MQ_LOGGING_CONSOLE_EXCLUDE_ID=AMQ5041I,AMQ5052I,AMQ5051I,AMQ5037I,AMQ5975I
ENV WLP_LOGGING_MESSAGE_FORMAT=json
# We can run as any UID
USER 1001
ENV MQ_CONNAUTH_USE_HTP=false
ENTRYPOINT ["runmqserver"]

###############################################################################
# Build stage to build C code for custom authorization service (developer-only)
###############################################################################
# Use the Go toolset image, which already includes gcc and the MQ SDK
FROM builder as cbuilder
USER 0
# Install the Apache Portable Runtime code (used for htpasswd hash checking)
RUN yum --assumeyes --disableplugin=subscription-manager install apr-devel apr-util-openssl apr-util-devel
COPY authservice/ /opt/app-root/src/authservice/
WORKDIR /opt/app-root/src/authservice/mqhtpass
RUN make all

###############################################################################
# Add default developer config
###############################################################################
FROM mq-server AS mq-dev-server
ARG BASE_IMAGE
ARG BASE_TAG
ARG GO_WORKDIR
LABEL summary="IBM MQ Advanced for Developers Server" \
      description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises" \
      vendor="IBM" \
      distribution-scope="private" \
      authoritative-source-url="https://www.ibm.com/software/passportadvantage/" \
      url="https://www.ibm.com/products/mq/advanced" \
      io.openshift.tags="mq messaging" \
      io.k8s.display-name="IBM MQ Advanced for Developers Server" \
      io.k8s.description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises" \
      base-image=$BASE_IMAGE \
      base-image-release=$BASE_TAG
USER 0
COPY --from=cbuilder /opt/app-root/src/authservice/mqhtpass/build/mqhtpass.so /opt/mqm/lib64/
COPY etc/mqm/*.ini /etc/mqm/
COPY etc/mqm/mq.htpasswd /etc/mqm/
COPY incubating/mqadvanced-server-dev/install-extra-packages.sh /usr/local/bin/
RUN chmod u+x /usr/local/bin/install-extra-packages.sh \
  && sleep 1 \
  && install-extra-packages.sh
COPY --from=builder $GO_WORKDIR/runmqdevserver /usr/local/bin/
# Copy template files
COPY incubating/mqadvanced-server-dev/*.tpl /etc/mqm/
# Copy web XML files for default developer configuration
COPY incubating/mqadvanced-server-dev/web /etc/mqm/web
RUN chown -R 1001:root /etc/mqm/* \
  && chmod -R g+w /etc/mqm/web \
  && chmod +x /usr/local/bin/runmq* \
  && chmod 0660 /etc/mqm/mq.htpasswd \
  && install --directory --mode 2775 --owner 1001 --group root /run/runmqdevserver
ENV MQ_DEV=true \
    MQ_ENABLE_EMBEDDED_WEB_SERVER=1 \
    MQ_GENERATE_CERTIFICATE_HOSTNAME=localhost \
    LD_LIBRARY_PATH=/opt/mqm/lib64 \
    MQ_CONNAUTH_USE_HTP=true \
    MQS_PERMIT_UNKNOWN_ID=true
USER 1001
ENTRYPOINT ["runmqdevserver"]
