# Ubuntu Development Environment

![Test status](https://github.com/hbraux/ubuntu/workflows/test/badge.svg)

Run the following command to install *features* locally:
```sh
curl -s https://raw.githubusercontent.com/hbraux/ubuntu/main/install.sh | bash -s FEATURE ...
```

Supported features:
* default (env git docker sbt maven)
* intellij
* python3
* netdata
* all

Limitations: 
* Only tested with Ubuntu 20.04 and 22.04

### Cloud VM

Run the following command *from your computer* to secure a Cloud VM running Ubuntu:
```sh
curl -s https://raw.githubusercontent.com/hbraux/ubuntu/main/cloud.sh | bash -s SERVER FEATURE ...
```
SERVER must be a FQDN

Supported features:
* default 
* minecraft
* http
* wordpress
