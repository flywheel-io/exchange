FROM python:2.7-alpine

RUN apk --no-cache add bash docker curl git tar

ENV JQ_URL "https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64"
RUN curl -L $JQ_URL > usr/local/bin/jq && chmod +x /usr/local/bin/jq

ENV GCLOUD_URL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-126.0.0-linux-x86_64.tar.gz"
RUN curl $GCLOUD_URL | tar xz -C /usr/local --strip-components 1

ADD bin/* /usr/local/bin/
