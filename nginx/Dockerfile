# a minimal Nginx container including ContainerPilot and a simple virtulhost config
FROM nginx:latest

# install some tooling
RUN apt-get update && \
    apt-get install -y \
    curl \
    bc \
    unzip && \
    rm -rf /var/lib/apt/lists/*

RUN curl -Lo /tmp/consul_template_0.14.0_linux_amd64.zip https://releases.hashicorp.com/consul-template/0.14.0/consul-template_0.14.0_linux_amd64.zip && \
    unzip /tmp/consul_template_0.14.0_linux_amd64.zip && \
    mv consul-template /bin

# get ContainerPilot release
ENV CONTAINERPILOT_VERSION 2.0.0
RUN export CP_SHA1=a82b1257328551eb93fc9a8cc1dd3f3e64664dd5 \
    && mkdir -p /opt/containerpilot \
    && curl -Lso /tmp/containerpilot.tar.gz \
         "https://github.com/joyent/containerpilot/releases/download/${CONTAINERPILOT_VERSION}/containerpilot-${CONTAINERPILOT_VERSION}.tar.gz" \
    && echo "${CP_SHA1}  /tmp/containerpilot.tar.gz" | sha1sum -c \
    && tar zxf /tmp/containerpilot.tar.gz -C /opt/containerpilot \
    && rm /tmp/containerpilot.tar.gz

# Add our configuration files and scripts
COPY opt/containerpilot /opt/containerpilot/
