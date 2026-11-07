FROM docker.io/library/ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq gcc g++ make curl ca-certificates git liburing-dev sqlite3 jq openssl unzip xz-utils zstd >/dev/null
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain leanprover/lean4:v4.35.0 >/dev/null 2>&1
ENV PATH=/root/.elan/bin:$PATH
RUN curl -sSfL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.94.0 >/dev/null 2>&1
ENV PATH=/root/.cargo/bin:$PATH
RUN apt-get update -qq && apt-get install -y -qq nodejs netcat-openbsd >/dev/null
RUN curl -sSfL https://github.com/mstange/samply/releases/download/samply-v0.13.1/samply-aarch64-unknown-linux-gnu.tar.xz | tar -xJ -C /usr/local/bin --strip-components=1 && samply --version
RUN curl -sSfL https://github.com/grafana/k6/releases/download/v2.3.0/k6-v2.3.0-linux-arm64.tar.gz | tar -xz -C /usr/local/bin --strip-components=1 && k6 version
