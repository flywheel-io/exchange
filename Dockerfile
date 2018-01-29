FROM python:2.7-alpine3.7

RUN apk --no-cache add bash coreutils curl docker git jq tar

RUN pip install jsonschema git+https://github.com/flywheel-io/gears.git

ENV GCLOUD_URL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-186.0.0-linux-x86_64.tar.gz"
RUN curl $GCLOUD_URL | tar xz -C /usr/local --strip-components 1

CMD ["/bin/sh"]
