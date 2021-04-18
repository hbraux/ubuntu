#!/bin/bash

ostype=$(sed -n 's/^ID=\(.*\)/\1/p' /etc/os-release | sed 's/"//g')
osversion=$(sed -n 's/^VERSION_ID=\(.*\)/\1/p' /etc/os-release | sed 's/"//g')

if [[ $ostype != ubuntu ]]; then
    echo "Error: this script requires Ubuntu"; exit 1
fi

if [[ $osversion != 18.04 && $osversion != 20.04 ]]; then
  if [[ $1 == -i ]]; then
    shift
  else
    echo "Error: this script has only been verified on Ubuntu 18.04 and 20.04. Add -i to ignore"; exit 1
  fi
fi

if [[ whoami == root ]]; then
    echo "Error: this script must not be run from root but from a sudo user"; exit 1
fi

if [[ $# -eq 0 ]]; then
    if [[ $0 == bash ]]; then
        echo "Usage: $0 FEATURE ..."
        exit
    fi
    defaults=$(grep "tags: \[.*,default" $0 | sed -e 's/.* \[//g;s/,default.*//g' | uniq | tr '\n' ' ')
    options=$(grep "tags: \[.*,never" $0 | sed -e 's/.* \[/* /g;s/,never.*//g' | uniq)
    echo "Usage: $0 FEATURE ...
Supported features:
* default ($defaults)
$options
* all"
    exit
fi
args="$*"
args="--tags ${args// /,}"
if [[ $1 == -v ]]; then
  shift
  args="-vvv $args"
fi

if [[ ! -f $HOME/.ssh/id_rsa.pub ]]; then
  echo "Error: no SSH keys found. You need to generate them (ssh-keygen)
and attach the publick key to your https://gitlab.com/ profile.
Continuing but installation may fail"
fi

# check sudo
sudo ls >/dev/null || exit 1

cd $HOME

which ansible-playbook >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "Installing Ansible..."
  sudo apt install software-properties-common
  sudo apt-add-repository --yes --update ppa:ansible/ansible
  sudo apt-get install --yes --quiet ansible
fi

cat >/tmp/install_desktop.yml<<'EOF'
- hosts: 127.0.0.1
  connection: local
  tasks:
    - name: set variables
      set_fact:
        wsl: "{{ 'microsoft' in ansible_facts.kernel }}"
        cacheurl: "{{ lookup('env', 'CACHE_URL')|default('') }}"
        oracle_version: 12.2
        oracle_release: 12.2.0.1.0-2
        oracle_db: fides
        conda_home: "{{ ansible_env.HOME }}/miniconda"
        idea_build: IU-211.6693.111
      tags: [always]

    - name: allow passwordless sudo for sudo group
      lineinfile:
        dest: /etc/sudoers
        regexp: '^%sudo'
        line: '%sudo ALL=(ALL) NOPASSWD: ALL'
        validate: 'visudo -cf %s'
      become: yes
      tags: [env,default,all]

    - name: create {{ ansible_env.HOME }}/bin
      file:
        path: "{{ ansible_env.HOME }}/bin"
        state: directory
      tags: [env,default,all]

    - name: update the PATH
      lineinfile:
        path: "{{ ansible_env.HOME }}/.bashrc"
        regexp: 'PATH=\$PATH:\$HOME/bin'
        line: 'PATH=$PATH:$HOME/bin'
      tags: [env,default,all]

    - name: install misc packages (make,jq,unzip,..)
      apt:
        name: ["make","jq","git","postgresql-client","unzip","libsnappy-dev"]
      become: yes
      tags: [env,default,all]

    - name: update vm.max_map_count to 262144 (Elasticsearch)
      sysctl:
        name: vm.max_map_count
        value: "262144"
      become: yes
      tags: [env,default,all]

    - name: update fs.aio-max-nr to 1048576 (ScyllaDB)
      sysctl:
        name: fs.aio-max-nr
        value: "1048576"
      become: yes
      tags: [env,default,all]

    - name: update perf_event_paranoid to 1
      sysctl:
        name: kernel.perf_event_paranoid
        value: "1"
      become: yes
      tags: [env,default,all]

    - name: update kptr_restrict to 0
      sysctl:
        name: kernel.kptr_restrict
        value: "0"
      become: yes
      tags: [env,default,all]

    - name: update inotify
      copy:
        content: |
          fs.inotify.max_user_watches = 524288
        dest: /etc/sysctl.d/99-inotify.conf
      register: inotify
      become: yes
      tags: [env,default,all]

    - name: refresh system
      shell: sysctl -p --system
      become: yes
      when: inotify.changed
      tags: [env,default,all]

    - name: install ntp
      apt:
        name: ntp
      become: yes
      tags: [ntp,all]

    - name: install Docker key
      apt_key:
        key: docker
        url: https://download.docker.com/linux/ubuntu/gpg
      become: yes
      tags: [docker,default,all]

    - name: add Docker CE repository
      apt_repository:
        repo: deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable
        update_cache: yes
      become: yes
      tags: [docker,default,all]

    - name: install Docker
      apt:
        name: [docker-ce, docker-ce-cli]
      become: yes
      tags: [docker,default,all]

    - name: add user {{ ansible_user_id }} to docker group
      user:
        name: "{{ ansible_user_id }}"
        groups: docker
        append: yes
      register: user_chg
      become: yes
      tags: [docker,default,all]

    - name: update .bashrc to start docker on WSL
      lineinfile:
        path: "{{ ansible_env.HOME }}/.bashrc"
        regexp: '.*docker start'
        line: "[[ ! -S /var/run/docker.sock ]] && sudo sysctl -p -q && sudo service docker start && sudo sed -i -e '$a172.17.0.1 local' /etc/hosts"
      tags: [docker,default,all]
      when: wsl

    - name: install docker-compose 1.25
      get_url:
        url: https://github.com/docker/compose/releases/download/1.25.0/docker-compose-Linux-x86_64
        dest: /usr/bin/docker-compose
        mode: 0755
      become: yes
      tags: [docker,default,all]

    - name: install OpenJDK 8
      apt:
        name: [openjdk-8-jdk, openjdk-8-source, openjdk-8-dbg]
      become: yes
      tags: [jdk,default,all]

    - name: install SBT key
      apt_key:
        id: 2EE0EA64E40A89B84B2DF73499E82A75642AC823
        keyserver: hkp://keyserver.ubuntu.com:80
      become: yes
      tags: [sbt,never,all]

    - name: add SBT repository
      apt_repository:
        repo: deb https://dl.bintray.com/sbt/debian /
        update_cache: yes
      become: yes
      tags: [sbt,never,all]

    - name: install SBT
      apt:
        name: sbt
      become: yes
      tags: [sbt,never,all]

    - name: install 3p for intellij
      apt:
        name: ["x11-apps","libxkbcommon-x11-0","libgbm-dev"]
      become: yes
      tags: [intellij,never,all]

    - name: create directory /opt/jetbrains
      file:
        path: /opt/jetbrains
        state: directory
        owner: "{{ ansible_user_id }}"
      become: yes
      tags: [intellij,never,all]

    - name: download Intellij builds list
      get_url:
        url: https://confluence.jetbrains.com/display/IDEADEV/IDEA+2021.1+latest+builds 
        dest: /tmp/idea_builds
      tags: [intellij,never,all]

    - name: try to find the latest build
      shell: sed -nE 's/.*Recent Changes(.{100}).*/\1/p;' /tmp/idea_builds | sed -e 's/.*IDEA //;s/<.*//'
      register: grepbuilds
      tags: [intellij,never,all]

    - name: set variable idea_build
      set_fact:
        idea_build: "IU-{{ grepbuilds.stdout }}"
      tags: [intellij,never,all]

    - name: check if Intellij build {{ idea_build }} is already installed
      stat:
        path: /opt/jetbrains/idea-{{ idea_build }}
      register: stat_idea
      tags: [intellij,never,all]

    - name: download Intellij {{ idea_build }}
      unarchive:
        src: https://download.jetbrains.com/idea/idea{{ idea_build }}.tar.gz
        remote_src: true
        dest: /opt/jetbrains/
      when: not stat_idea.stat.exists
      tags: [intellij,never,all]

    - name: fix permission /opt/jetbrains
      file:
        path: /opt/jetbrains
        owner: "{{ ansible_user_id }}"
      become: yes
      tags: [intellij,never,all]

    - name: update script $HOME/bin/idea
      copy:
        content: |
           /opt/jetbrains/idea-{{ idea_build }}/bin/idea.sh >/opt/jetbrains/{{ idea_build }}.log 2>&1 &
        dest: "{{ ansible_env.HOME }}/bin/idea"
        owner: "{{ ansible_user_id }}"
        mode: a+rx
      tags: [intellij,never,all]

    - name: install Maven
      apt:
        name: maven
      become: yes
      tags: [maven,default,all]

    - name: install NodeSource key
      apt_key:
        key: nodesource
        url: https://deb.nodesource.com/gpgkey/nodesource.gpg.key
      become: yes
      tags: [npm,never,all]

    - name: add nodesource repository
      apt_repository:
        repo: deb [arch=amd64] https://deb.nodesource.com/node_8.x bionic main
        update_cache: yes
        filename: nodesource
      become: yes
      tags: [npm,never,all]

    - name: install npm
      apt:
        name: nodejs
      become: yes
      tags: [npm,never,all]

    - name: install python3
      apt:
        name: ["python3","python3-pip"]
      become: yes
      tags: [python3,never,all]

    - name: install python3 packages
      pip:
        executable: pip3
        name: ["avro","kafka","requests"]
      become: yes
      tags: [python3,never,all]

    - name: install cqlsh
      pip:
        executable: pip2
        name: ["cqlsh"]
      become: yes
      tags: [python3,never,all]

    - name: get netdata version file
      get_url:
        url: https://raw.githubusercontent.com/netdata/binary-packages/master/netdata-latest.gz.run
        dest: /tmp/netdata-version
      tags: [netdata,never,all]

    - name: get netdata version
      shell: cat /tmp/netdata-version
      register: cat_cmd
      changed_when: false
      tags: [netdata,never,all]

    - name: download netdata binary
      get_url:
        url: https://raw.githubusercontent.com/netdata/binary-packages/master/{{ cat_cmd.stdout }}
        dest: /tmp/netdata.gz.run
        mode: 0755
      tags: [netdata,never,all]

    - name: install netdata
      shell: /tmp/netdata.gz.run --quiet --accept --noprogress --nox11
      args:
        creates: /opt/netdata
      become: yes
      tags: [netdata,never,all]

    - name: check netdata service (port 19999)
      wait_for:
        port: 19999
      tags: [netdata,never,all]

    - name: install libaio
      apt:
        name: libaio1
      become: yes
      tags: [oracle,never,all]

    - name: set oracle packages
      set_fact:
        orapackages:
          - oracle-instantclient{{ oracle_version }}-basic_{{ oracle_release }}_amd64.deb
          - oracle-instantclient{{ oracle_version }}-devel_{{ oracle_release }}_amd64.deb
          - oracle-instantclient{{ oracle_version }}-jdbc_{{ oracle_release }}_amd64.deb
          - oracle-instantclient{{ oracle_version }}-sqlplus_{{ oracle_release }}_amd64.deb
      tags: [oracle,never,all]

    - name: get packages from {{ cacheurl }}
      get_url:
        url: "{{ cacheurl }}/oracle/{{ item }}"
        dest: /tmp
        validate_certs: false
      with_items: "{{ orapackages }}"
      when: cacheurl != ""
      tags: [oracle,never,all]

    - name: install oracle client {{ oracle_version }}
      apt:
        deb: /tmp/{{ item }}
      with_items: "{{ orapackages }}"
      become: yes
      tags: [oracle,never,all]

    - name: create oracle client directories
      file:
        path: /usr/lib/oracle/{{ oracle_version }}/client64/{{ item }}
        state: directory
        mode: a+rx
      with_items:
        - rdbms/public
        - network/admin
      become: yes
      tags: [oracle,never,all]

    - name: create tnsnames.ora
      copy:
        content: |
          {{ oracle_db }}=(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=1521)))(CONNECT_DATA=(SERVICE_NAME={{ oracle_db }})))
        dest: /usr/lib/oracle/{{ oracle_version }}/client64/network/admin/tnsnames.ora
      become: yes
      tags: [oracle,never,all]

    - name: create /etc/profile.d/oracle.sh
      copy:
        content: |
          export ORACLE_HOME=/usr/lib/oracle/{{ oracle_version }}/client64
          export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
          export PATH=$PATH:$ORACLE_HOME/bin
          export NLS_LANG=American_America.UTF8
          export TZ=Europe/Paris
          export ORA_SDTZ=Europe/Paris
        dest: /etc/profile.d/oracle.sh
      become: yes
      tags: [oracle,never,all]

    - name: update .bashrc to load Oracle env
      lineinfile:
        path: "{{ ansible_env.HOME }}/.bashrc"
        regexp: 'source /etc/profile.d/oracle.sh'
        line: 'source /etc/profile.d/oracle.sh'
      tags: [oracle,never,all]

    - name: install DBeaver key
      apt_key:
        key: dbeaver
        url: https://dbeaver.io/debs/dbeaver.gpg.key
      become: yes
      tags: [dbeaver,never,all]

    - name: add DBeaver CE repository
      apt_repository:
        repo: deb https://dbeaver.io/debs/dbeaver-ce /
        update_cache: yes
      become: yes
      tags: [dbeaver,never,all]

    - name: install DBeaver CE
      apt:
        name: dbeaver-ce
      become: yes
      tags: [dbeaver,never,all]

    - name: install terraform
      unarchive:
        src: https://releases.hashicorp.com/terraform/0.12.23/terraform_0.12.23_linux_amd64.zip
        dest: /usr/bin/
        remote_src: yes
      become: yes
      tags: [terraform,never,all]

    - name: download mini conda
      get_url:
        url: https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
        dest: /tmp/miniconda.sh
      tags: [conda,never,all]

    - name: install mini conda in {{ conda_home }}
      shell: bash /tmp/miniconda.sh -b -p {{ conda_home }}
      args:
        creates: "{{ conda_home }}"
      tags: [conda,never,all]

    - name: update .bashrc for conda
      blockinfile:
        path: "{{ ansible_env.HOME }}/.bashrc"
        block: |
          PATH=$PATH:{{ conda_home }}/bin
          . {{ conda_home }}/etc/profile.d/conda.sh
      tags: [conda,never,all]

    - debug:
        msg: "WARNING: YOU NEED TO REBOOT NOW!"
      when: user_chg.changed
      tags: [default,all]
EOF

echo "Executing embedded playbook..."
ansible-playbook /tmp/install_desktop.yml -i localhost, $args

