#!/bin/bash
# Install a Cloud VM

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
  echo "Usage: $0 SERVER"; exit
fi
vm=$1

# first check if the box is reachable
ping -c1 $vm >/dev/null || die "Cannot reach $vm"


# check if we can reach with SSH
ssh -p $PORT -o StrictHostKeyChecking=no $vm echo
if [[ $? -ne 0 ]]; then
  ssh-keygen -f $HOME/.ssh/known_hosts -R $vm
  info "Securing $vm"
  echo -e "Cloud admin ($ADMIN) password: \c"
  read pass
  cat >$PBOOK <<EOF
- hosts: $vm
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
  ansible-playbook -i $vm, -b -e username=$USER --ssh-extra-args="-o PubkeyAuthentication=no -o StrictHostKeyChecking=no" $PBOOK || die
  info "Secured completed. Re-run the script in a few seconds"
  exit
fi

info "Setting up $vm"
cat > $PBOOK <<EOF
- hosts: $vm
  vars:
    ansible_port: $PORT
  tasks:
  - name: remove Cloud admin user $ADMIN
    user:
      name: $ADMIN
      remove: yes
    become: yes
  - name: run apt update and upgrade
    apt:
      upgrade: safe
      update_cache: yes
      cache_valid_time: 86400
    become: yes
EOF
ansible-playbook $PBOOK -i $vm,
rm -f $PBOOK

