# a Node.js application container including ContainerPilot
FROM node:slim

# install curl
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    graphicsmagick \
    python \
    git \
    unzip \
    curl && \
    rm -rf /var/lib/apt/lists/*

# touchbase is our application; we're using a fork that removes
# the requirement for SendGrid verification of emails
# node-gyp is required to support the Couchbase C libs for Node
RUN git clone -b no_sendgrid https://github.com/tgross/touchbase.git /tmp && \
    npm install -g \
    node-gyp \
    bower \
    /tmp/TouchbaseModular

RUN cd /usr/local/lib/node_modules/Couch411 && \
    echo '{ "allow_root": true }' > /root/.bowerrc && \
    bower install

# generate a self-signed cert. We would terminate any SSL at the load balancer but
# Touchbase won't start without at least a self-signed cert installed.
RUN openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes \
    -subj "/C=US/ST=None/L=None/O=None/CN=example.com"

# we use consul-template to re-write our config.json
RUN curl -Lo /tmp/consul_template_0.14.0_linux_amd64.zip https://releases.hashicorp.com/consul-template/0.14.0/consul-template_0.14.0_linux_amd64.zip && \
    unzip /tmp/consul_template_0.14.0_linux_amd64.zip && \
    mv consul-template /usr/local/bin

# get ContainerPilot release
ENV CONTAINERPILOT_VERSION 2.0.0
RUN export CP_SHA1=a82b1257328551eb93fc9a8cc1dd3f3e64664dd5 \
    && mkdir -p /opt/containerpilot \
    && curl -Lso /tmp/containerpilot.tar.gz \
         "https://github.com/joyent/containerpilot/releases/download/${CONTAINERPILOT_VERSION}/containerpilot-${CONTAINERPILOT_VERSION}.tar.gz" \
    && echo "${CP_SHA1}  /tmp/containerpilot.tar.gz" | sha1sum -c \
    && tar zxf /tmp/containerpilot.tar.gz -C /opt/containerpilot \
    && rm /tmp/containerpilot.tar.gz

# add ContainerPilot and configuration
COPY touchbase.json /opt/containerpilot/
COPY update-config.sh /opt/containerpilot/
COPY sensor.sh /opt/containerpilot/
