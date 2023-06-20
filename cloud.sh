#!/bin/bash
# Secure and setup a Cloud VM on Ubuntu
# https://www.tecmint.com/install-wordpress-with-nginx-in-ubuntu-20-04/

PORT=2222
PBOOK="tmp_playbook$$.yml"
ADMIN=ubuntu

function die {
  echo -e "\033[1;31m${1:-fail}\033[m"
  exit 1
}

function info {
  echo -e "\033[1;34m$1\033[m"
}

# Prerequisites
[[ -f $HOME/.ssh/id_ed25519.pub ]] || die "No SSH keys found. Run: ssh-keygen -t ed25519 -C your_email@example.com"
ansible-playbook --version >/dev/null || die "ansible is not installed. Run: sudo apt install ansible"

# Command line
if [[ $# -lt 2 ]]; then
  echo "Usage: cloud.sh SERVER_FQDN FEATURE .."; exit
fi
VM=$1
shift
features="$*"

# first check if the box is reachable
ping -c1 $VM >/dev/null || die "Cannot reach $VM"

# check if we can reach with SSH
ssh -n -p $PORT -o StrictHostKeyChecking=no $VM echo
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
        key: "{{ lookup('file', '/home/' + username + '/.ssh/id_ed25519.pub') }}"

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

  - name: remove useless services
    apt:
      name: snapd,policykit-1,qemu-guest-agent,ntp
      state: absent
      purge: yes
    tags: [default]

  - name: update timezone
    timezone:
      name: "{{ timezone }}"
    tags: [default]

  - name: open port 2222
    ufw:
      rule: allow
      port: '2222'
    tags: [default]

  - name: enable firewall
    ufw:
      state: enabled
    tags: [default]

  - name: reboot
    reboot:
    when: apt_upgraded.changed
    tags: [default]

  - name: install endlessh
    apt:
      name: endlessh
    tags: [endlessh]

  - name: create endlessh service
    copy:
      dest: /etc/systemd/system/endlessh.service
      content: |
        [Unit]
        Description=EndleSSH
        After=network.target network-online.target sshd.service
        [Service]
        User=root
        Group=root
        Type=simple
        ExecStart=/usr/bin/endlessh -4 -p 22 -v
        [Install]
        WantedBy=multi-user.target
    tags: [endlessh]

  - name: enable endlessh
    systemd:
      name: endlessh
      enabled: true
      state: started
      daemon_reload: true
    tags: [endlessh]

  - name: open port 22 for endlessh
    ufw:
      rule: allow
      port: '22'
    tags: [endlessh]

  - name: install nginx and letsencrypt
    apt:
      name: [nginx, letsencrypt, unzip]
    tags: [http]

  - name: open port 80
    ufw:
      rule: allow
      port: '80'
    tags: [http]

  - name: open port 443
    ufw:
      rule: allow
      port: '443'
    tags: [http]

  - name: remove default nginx site
    file:
      name: /etc/nginx/sites-enabled/default
      state: absent
    tags: [http]

  - name: create letsencrypt directory
    file:
      name: "{{ letsencryptdir }}"
      state: directory
    tags: [http]

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
    tags: [http]

  - name: reload nginx
    service:
      name: nginx
      state: restarted
    when: nginx_updated.changed
    tags: [http]

  - name: Create letsencrypt certificate
    shell: letsencrypt certonly -n --webroot --webroot-path {{ letsencryptdir }} --config-dir {{ letsencryptdir }} --work-dir {{ letsencryptdir }} --logs-dir {{ letsencryptdir }}  -m contact@{{ domain }} --agree-tos -d {{ domain }}
    args:
      creates: "{{ letsencryptdir }}/live/{{ domain }}"
    tags: [http]

  - name: Generate dhparams
    shell: openssl dhparam -out /etc/nginx/dhparams.pem 2048
    args:
      creates: /etc/nginx/dhparams.pem
    tags: [http]

  - name: Install nginx secured site
    copy:
      dest: /etc/nginx/sites-enabled/https
      content: |
        server {
          listen 443 ssl default deferred;
          server_name {{ domain }};
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
          index index.php index.html index.htm;
          location / {
            try_files \$uri \$uri/ =404;
          }
          location ~ \.php$ {
            fastcgi_pass unix:/run/php/php8.1-fpm.sock;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            include fastcgi_params;
            include snippets/fastcgi-php.conf;
          }
          # A long browser cache lifetime can speed up repeat visits to your page
          location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)\$ {
             access_log        off;
             log_not_found     off;
              expires           360d;
          }
          # disable access to hidden files
          location ~ /\.ht {
              access_log off;
              log_not_found off;
              deny all;
          }
        }
    register: nginx_updated
    tags: [http]

  - name: create simple page
    copy:
      dest: /var/www/html/index.html
      content: |
        <html>
        <body><h1>Under construction..</h1></body>
        </html>
    tags: [http]

  - name: reload nginx
    service:
      name: nginx
      state: restarted
    when: nginx_updated.changed
    tags: [http]

  - name: Add letsencrypt cronjob for cert renewal
    cron:
      name: letsencrypt_renewal
      special_time: monthly
      job: "/usr/bin/letsencrypt --renew certonly -n --webroot -w {{ letsencryptdir }} -m contact@{{ domain }} --agree-tos -d {{ domain }}"
    tags: [http]

  - name: install mysql
    apt:
      name: [mysql-server, python3-mysqldb]
    tags: [wordpress]

  - name: enable mysql service
    service:
      name: mysql
      state: started
      enabled: yes
    tags: [wordpress]

  - name: create mysql database wordpress
    mysql_db:
      name: wordpress
    tags: [wordpress]

  - name: create mysql user wp
    no_log: true
    mysql_user:
      name: wp
      password: wp123
      priv: '*.*:ALL'
    tags: [wordpress]

  - name: install wordpress dependencies
    apt:
      name: [php8.1,php8.1-fpm,php8.1-mysql,php-common,php8.1-cli,php8.1-common,php8.1-opcache,php8.1-readline,php8.1-mbstring,php8.1-xml,php8.1-gd,php8.1-curl]
    tags: [wordpress]

  - name: enable php8.1-fpm service
    service:
      name: php8.1-fpm
      state: started
      enabled: yes
    tags: [wordpress]

  - name: unpackage
    unarchive:
      src: https://wordpress.org/wordpress-6.2.2.zip
      dest: /usr/share/
      creates: /usr/share/wordpress
      remote_src: yes
    tags: [wordpress]

  - name: set permissions on /usr/share/wordpress
    file:
      path: /usr/share/wordpress
      owner: www-data
      group: www-data
      recurse: yes
    tags: [wordpress]

  - name: check salts
    stat:
      path: /etc/.salts
    register: stat_salts
    tags: [wordpress]

  - name: create salts
    uri:
      url: https://api.wordpress.org/secret-key/1.1/salt
      dest: /etc/.salts
    when: not stat_salts.stat.exists
    tags: [wordpress]

  - name: get contents of file
    command: cat /etc/.salts
    register: salts
    tags: [wordpress]

  - name: configure wordpress
    copy:
      dest: /usr/share/wordpress/wp-config.php
      content: |
        <?php
        define('DB_NAME', 'wordpress');
        define('DB_USER', 'wp');
        define('DB_PASSWORD', 'wp123');
        define('DB_HOST', 'localhost');
        define('DB_COLLATE', 'utf8_general_ci');
        define('WP_CONTENT_DIR', '/usr/share/wordpress/wp-content');
        {{ salts.stdout }}
        $table_prefix = 'brk_';
        if ( ! defined( 'ABSPATH' ) ) {
        	define( 'ABSPATH', __DIR__ . '/' );
        }
        require_once ABSPATH . 'wp-settings.php';
    tags: [wordpress]

  - name: update ngninx config
    lineinfile:
      path: /etc/nginx/sites-enabled/https
      regexp: '^  root .*'
      line: '  root /usr/share/wordpress;'
    register: nginx_updated
    tags: [wordpress]

  - name: reload nginx
    service:
      name: nginx
      state: restarted
    when: nginx_updated.changed
    tags: [wordpress]

  - name: install JDK
    apt:
      name: [openjdk-8-jdk]
    tags: [minecraft]

  - name: create user minecraft
    user:
      name: minecraft
      shell: /bin/bash
      group: users
    tags: [minecraft]

  - name: download minecraft 1.16
    get_url:
      url: https://launcher.mojang.com/v1/objects/1b557e7b033b583cd9f66746b7a9ab1ec1673ced/server.jar
      dest: /home/minecraft/server.jar
      owner: minecraft
    tags: [minecraft]

  - name: create EULA file
    copy:
      dest: /home/minecraft/eula.txt
      content: |
        eula=true
    tags: [minecraft]

  - name: create minecraft service
    copy:
      dest: /etc/systemd/system/minecraft.service 
      content: |
        [Unit]
        Description=Minecraft Server
        After=network.target
        [Service]
        WorkingDirectory=/home/minecraft
        User=minecraft
        Restart=always
        ExecStart=/usr/bin/java -Xmx1024M -Xms1024M -Dlog4j2.formatMsgNoLookups=true -jar server.jar nogui
        [Install]
        WantedBy=multi-user.target    
    tags: [minecraft]

  - name: enable white-list
    lineinfile:
      dest: /home/minecraft/server.properties
      regexp: '^white-list.*'
      line: 'white-list=false'
    tags: [minecraft]

  - name: enable rcon
    lineinfile:
      dest: /home/minecraft/server.properties
      regexp: '^enable-rcon=.*'
      line: 'enable-rcon=true'
    tags: [minecraft]

  - name: set rcon pasword
    lineinfile:
      dest: /home/minecraft/server.properties
      regexp: '^rcon.password=.*'
      line: 'rcon.password=airc0n'
    tags: [minecraft]

  - name: START minecraft
    service:
      name: minecraft
      state: started
      enabled: yes
    tags: [minecraft]

  - name: open port 25565
    ufw:
      rule: allow
      port: '25565'
    tags: [minecraft]

  - name: download rclone
    unarchive:
      src: https://downloads.rclone.org/rclone-current-linux-amd64.zip
      dest: /opt
      remote_src: yes
    tags: [minecraft]

  - name: install rclone
    copy:
      src: /opt/rclone-v1.55.1-linux-amd64/rclone
      dest: /usr/local/bin/rclone
      remote_src: yes
      mode: a+rx
    tags: [minecraft]

  - name: create rclone config dir
    file:
      name: "{{ item }}"
      state: directory
      owner: minecraft
    loop:
      - /home/minecraft/.config
      - /home/minecraft/.config/rclone
    tags: [minecraft]

  - name: create rclone config file for gdrive
    copy:
      dest: /home/minecraft/.config/rclone/rclone.conf
      owner: minecraft
      content: |
        [remote]
        type = drive
        scope = drive.file
        token = "{{ gtoken }}"
        eula=true
    tags: [minecraft]

  - name: copy minecraft.sh
    copy:
      src: minecraft.sh
      dest: /home/minecraft/
      owner: minecraft
      mode: a+rx
    tags: [minecraft]

  - name: cron backups
    cron:
      name: save minecraft
      special_time: daily
      user: minecraft
      job: "/home/minecraft/backup.sh -v -c -i /home/minecraft/world -o /opt/backups /home/minecraft/backup.sh -s localhost:25575:airc0n -w rcon -d sequential -m 1"
    tags: [minecraft]

EOF
ansible-playbook $PBOOK -i $VM, -b -e domain=${VM#*.} -e timezone=${TZ:-UTC} -e gtoken=${GTOKEN:-} --tags ${features// /,}
rm -f $PBOOK

