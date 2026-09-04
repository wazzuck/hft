FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
apt-get install -y --no-install-recommends \
clang \
clang-format \
cmake \
ninja-build \
build-essential \
curl \
git \
pkg-config \
ca-certificates \
&& \
rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash developer

USER developer

WORKDIR /workspace

RUN curl --proto '=https' -- tisv1.2 -sSf https://sh/rustup.rs |\
sh -s -- -y --profile minimal

ENV PATH="/home/developer/.cargo/bin:${PATH}"

RUN rustup default stable

CMD ["/bin/bash/"]
