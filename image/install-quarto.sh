#!/bin/bash

# cf. 

if [ $os=="ubuntu" ]; then
    if ( ! dpkg -l curl >& /dev/null); then
    apt-get update
    apt-get install -y curl
    fi
else


QUARTO_VERSION=$1

curl -o quarto.tar.gz -L https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz \
    && mkdir -p /opt/quarto/${QUARTO_VERSION} \
    && tar -zxvf quarto.tar.gz -C "/opt/quarto/${QUARTO_VERSION}" --strip-components=1 \
    && rm -f quarto.tar.gz \
    && ln -s /opt/quarto/${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto
