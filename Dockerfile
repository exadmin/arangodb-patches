################################################################
# Stage 1: Build ArangoDB and install to /opt/arangodb-dist
################################################################
ARG TAG=v3.11.14
FROM debian:12 AS builder
ARG TAG

# 1. Installing dependencies
RUN apt-get update && apt-get install --no-install-recommends -y \
  build-essential cmake \
  clang-16 lld-16 llvm-16 libomp-16-dev \
  libopenblas-dev libssl-dev \
  python3 python3-clang-16 libabsl-dev \
  git-core wget unzip tar nodejs npm && \
  npm install -g yarn && apt-get clean -y

# 2. Cloning ArangoDB
RUN git clone --branch ${TAG} --depth 1 --recurse-submodules \
  https://github.com/arangodb/arangodb.git /opt/arangodb/src

# 3. Applying patches
COPY patches /opt/arangodb/src/patches
RUN cd /opt/arangodb/src && \
  for p in patches/*.patch; do \
    echo "Applying $p…"; \
    git apply -p1 --ignore-space-change --ignore-whitespace "$p"; \
  done

# 4. Building with DESTDIR
RUN mkdir /opt/arangodb/build && cd /opt/arangodb/build && \
  cmake /opt/arangodb/src \
    -DCMAKE_C_COMPILER=/usr/bin/clang-16 \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++-16 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_FAIL_ON_WARNINGS=off \
    -DUSE_GOOGLE_TESTS=off \
    -DUSE_MAINTAINER_MODE=off \
    -DUSE_JEMALLOC=Off \
    -DCMAKE_C_FLAGS='-w -std=c11 -fopenmp' \
    -DCMAKE_CXX_FLAGS='-w -std=c++17 -fopenmp' && \
  make -j$(nproc) install DESTDIR=/opt/arangodb-dist

################################################################
# Stage 2: Debian runtime
################################################################
FROM debian:12-slim
LABEL maintainer="Qubership <bot@qubership.com>"

ARG TAG
ENV ARANGO_VERSION=${TAG}
ENV PATH="/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:$PATH"

# 1. Installing runtime-dependencies
RUN apt-get update && apt-get install --no-install-recommends -y \
  bash gnupg pwgen binutils numactl libssl3 libatomic1 libomp5 nodejs npm && \
  npm install -g yarn && \
  yarn global add foxx-cli && \
  apt-get clean && rm -rf /var/lib/apt/lists/**


# 2. Creating "arangodb" user and group
RUN groupadd --system arangodb && \
    useradd --system --gid arangodb --home-dir /var/lib/arangodb3 --shell /bin/false arangodb

# 3. Installed binnary files copying
COPY --from=builder /opt/arangodb-dist/usr /usr

# 4. Ensure simlinks and configuration files
RUN mkdir -p /etc/arangodb3 && \
    ln -sf /usr/etc/arangodb3/arangod.conf /etc/arangodb3/arangod.conf && \
    ln -sf /usr/sbin/arangod /usr/bin/arangod

# 4. Setup grants and volumes
RUN mkdir -p /var/lib/arangodb3 /var/lib/arangodb3-apps /var/log/arangodb3 && \
    chgrp -R 0 /var/lib/arangodb3 /var/lib/arangodb3-apps /var/log/arangodb3 && \
    chmod -R 775 /var/lib/arangodb3 /var/lib/arangodb3-apps /var/log/arangodb3 && \
    echo "UTC" > /etc/timezone

VOLUME ["/var/lib/arangodb3", "/var/lib/arangodb3-apps"]

# 5. Entrypoint
COPY docker-entrypoint.sh /entrypoint.sh
COPY docker-foxx.sh       /usr/bin/foxx
RUN chmod +x /entrypoint.sh /usr/bin/foxx

EXPOSE 8529
ENTRYPOINT ["bash", "/entrypoint.sh"]
CMD ["arangod"]