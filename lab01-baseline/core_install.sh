#!/usr/bin/bash -x

sudo apt-get update && \
sudo apt-get install -y \
git \
curl \
tmux \
wget \
unzip \
tree \
python3 \
python3-pip \
python3-venv \
openssh-client

EDITOR=vi
