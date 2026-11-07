FROM docker.io/library/ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq gcc g++ make curl ca-certificates git liburing-dev sqlite3 jq openssl unzip xz-utils zstd >/dev/null
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain leanprover/lean4:v4.35.0 >/dev/null 2>&1
ENV PATH=/root/.elan/bin:$PATH
