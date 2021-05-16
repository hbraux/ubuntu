#!/bin/bash
# Secure and setup a Cloud VM on Ubuntu

PORT=2222
PBOOK="/tmp/playbook$$.yml"
ADMIN=ubuntu

function die {
  echo -e "\033[1;31m${1:-fail}\033[m"
  exit 1
}

function info {
  echo -e "\033[1;34m$1\033[m"
}

# Prerequisites
[[ -f $HOME/.ssh/id_rsa.pub ]] || die "No SSH keys found. Run: ssh-keygen -t rsa -b 4096 -C your_email@example.com"
[[ -x /usr/bin/ansible-playbook ]] || die "ansible is not installed. Run: sudo apt install ansible"
[[ -x /usr/bin/sshpass ]] || die "sshpass is not installed. Run: sudo apt install sshpass"

# Command line
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 FQDN [FEATURE]"; exit
fi
VM=$1
args=""
shift
if [[ $# -ne 0 ]]; then
  args="$*"
  args="--tags ${args// /,}"
else
  args="--tags default"
fi

# first check if the box is reachable
ping -c1 $VM >/dev/null || die "Cannot reach $VM"


# check if we can reach with SSH
ssh -p $PORT -o StrictHostKeyChecking=no $VM echo
if [[ $? -ne 0 ]]; then
  ssh-keygen -f $HOME/.ssh/known_hosts -R $VM
  info "Securing $VM"
  echo -e "Cloud admin ($ADMIN) password: \c"
  read pass
  cat >$PBOOK <<EOF
- hosts: $VM
  vars:
    ansible_user: $ADMIN
    ansible_password: $pass
  tasks:
    - name: allow passwordless sudo for sudo group
      lineinfile:
        dest: /etc/sudoers
        regexp: '^%sudo'
        line: '%sudo ALL=(ALL) NOPASSWD: ALL'
        validate: 'visudo -cf %s'

    - name: create user {{ username }}
      user:
        name: "{{ username }}"
        shell: /bin/bash
        group: users
        groups: sudo

    - name: add public key to user {{ username }}
      authorized_key:
        user: "{{ username }}"
        key: "{{ lookup('file', '/home/' + username + '/.ssh/id_rsa.pub') }}"

    - name: change sshd port to $PORT
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^.?Port 22'
        line: 'Port $PORT'

    - name: disable PasswordAuthentication
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^.?PasswordAuthentication yes'
        line: 'PasswordAuthentication no'

    - name: disable Root login
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^.?PermitRootLogin yes'
        line: 'PermitRootLogin No'

    - name: reboot the server
      command: shutdown -r 1
      
EOF
  ansible-playbook -i $VM, -b -e username=$USER --ssh-extra-args="-o PubkeyAuthentication=no -o StrictHostKeyChecking=no" $PBOOK || die
  info "Secured completed. Re-run the script in a few seconds"
  exit
fi

info "Setting up $VM"
cat > $PBOOK <<EOF
- hosts: $VM
  vars:
    ansible_port: $PORT
    letsencryptdir: "/var/www/letsencrypt"
  tasks:
  - name: remove Cloud admin user $ADMIN
    user:
      name: $ADMIN
      remove: yes
    tags: [default]

  - name: run apt update and upgrade
    apt:
      upgrade: safe
      update_cache: yes
      cache_valid_time: 864000
    register: apt_upgraded
    tags: [default]

  - name: reboot
    reboot:
    when: apt_upgraded.changed
    tags: [default]

  - name: install nginx and letsencrypt
    apt:
      name: ["nginx","letsencrypt"]
    tags: [web]

  - name: remove default nginx site
    file:
      name: /etc/nginx/sites-enabled/default
      state: absent
    tags: [web]

  - name: create letsencrypt directory
    file:
      name: "{{ letsencryptdir }}"
      state: directory
    tags: [web]

  - name: install nginx site for letsencrypt
    copy:
      dest: /etc/nginx/sites-enabled/http
      content: |
        server_tokens off;
        server {
          listen 80 default_server;
          server_name {{ domain }};
          location /.well-known/acme-challenge {
            root {{ letsencryptdir }};
            try_files \$uri \$uri/ =404;
          }
          location / {
            rewrite ^ https://{{ domain }}\$request_uri? permanent;
          }
        }
    register: nginx_updated
    tags: [web]

  - name: reload nginx
    service:
      name: nginx
      state: restarted
    when: nginx_updated.changed
    tags: [web]

  - name: Create letsencrypt certificate
    shell: letsencrypt certonly -n --webroot --webroot-path {{ letsencryptdir }} --config-dir {{ letsencryptdir }} --work-dir {{ letsencryptdir }} --logs-dir {{ letsencryptdir }}  -m contact@{{ domain }} --agree-tos -d {{ domain }}
    args:
      creates: "{{ letsencryptdir }}/live/{{ domain }}"
    tags: [web]

  - name: Generate dhparams
    shell: openssl dhparam -out /etc/nginx/dhparams.pem 2048
    args:
      creates: /etc/nginx/dhparams.pem
    tags: [web]

  - name: Install nginx secured site
    copy:
      dest: /etc/nginx/sites-enabled/https
      content: |
        server {
          listen 443 ssl default deferred;
          server_name {{ domain }};
          ssl on;
          ssl_certificate         {{ letsencryptdir }}/live/{{ domain }}/fullchain.pem;
          ssl_certificate_key     {{ letsencryptdir }}/live/{{ domain }}/privkey.pem;
          ssl_trusted_certificate {{ letsencryptdir }}/live/{{ domain }}/fullchain.pem;
          ssl_session_cache shared:SSL:50m;
          ssl_session_timeout 5m;
          ssl_stapling on;
          ssl_stapling_verify on;
          ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
          ssl_ciphers "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA256:AES128-SHA256:AES256-SHA:AES128-SHA:DES-CBC3-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!MD5:!PSK:!RC4";
          ssl_dhparam /etc/nginx/dhparams.pem;
          ssl_prefer_server_ciphers on;
          root /var/www/html;
          index index.html index.htm;
          location / {
            try_files \$uri \$uri/ =404;
          }
        }
    register: nginx_updated
    tags: [web]

  - name: create simple page
    copy:
      dest: /var/www/html/index.html
      content: |
        <html>
        <body><h1>Under construction..</h1></body>
        </html>
    tags: [web]

  - name: reload nginx
    service:
      name: nginx
      state: restarted
    when: nginx_updated.changed
    tags: [web]

  - name: Add letsencrypt cronjob for cert renewal
    cron:
      name: letsencrypt_renewal
      special_time: monthly
      job: "/usr/bin/letsencrypt --renew certonly -n --webroot -w {{ letsencryptdir }} -m contact@{{ domain }} --agree-tos -d {{ domain }}"
    tags: [web]

EOF
ansible-playbook $PBOOK -i $VM, -b -e domain=${VM#*.} $args
rm -f $PBOOK

