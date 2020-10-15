FROM ubuntu:18.04

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get -qq update && apt-get install -y -qq curl sudo

RUN useradd -ms /bin/bash test \
    && echo "test ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

COPY .ssh /home/test/.ssh
RUN chown -R test /home/test/.ssh

USER test
WORKDIR /home/test








