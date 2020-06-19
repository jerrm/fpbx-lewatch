#!/bin/bash

fullme="$(realpath -- "$0")"
baseme="$(basename -- "$0")"
me="${baseme%.*}"

rule="INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment ${me// /_}"
timeout=60

addRule() {
  echo "insert: $rule"
  iptables -w -C $rule 2>/dev/null || iptables -w -I $rule
  sleep $timeout
  deleteRule
}

deleteRule() {
  while iptables -w -C $rule 2>/dev/null; do
    echo "delete: $rule"
    iptables -w -D $rule
    sleep 0.1
  done
}

install() {
  # (re)create fpbx le web folders
  chattr -R -i /var/www/html/.well-known /var/www/html/.freepbx-known
  rm -rf /var/www/html/.well-known /var/www/html/.freepbx-known
  mkdir -p /var/www/html/.well-known/acme-challenge /var/www/html/.freepbx-known
  chown -R asterisk:asterisk /var/www/html/.well-known /var/www/html/.freepbx-known
  # prevent folders from being deleted for stable incrond usage
  touch /var/www/html/.well-known/acme-challenge/.nodelete /var/www/html/.freepbx-known/.nodelete
  chattr +i /var/www/html/.well-known/acme-challenge/.nodelete /var/www/html/.freepbx-known/.nodelete
  # install incrond
  [ -f /etc/redhat-release ] && {
    yum -y install incron
    systemctl enable incrond
    systemctl start incrond
  }  || {
    apt-get -y install incron
    systemctl enable incron
    systemctl start incron
  }
  # monitor fpbx le web folders
  {
    echo "/var/www/html/.well-known/acme-challenge IN_CREATE,IN_DELETE $(printf %q "$fullme") "'$@ $# $% $&'
    echo "/var/www/html/.freepbx-known IN_CREATE,IN_DELETE $(printf %q "$fullme") "'$@ $# $% $&'
  } > "/etc/incron.d/$me"
  exit 0
}

uninstall() {
  deleteRule
  rm "/etc/incron.d/$me"
}

main() {
  echo "START Path:$1, File:$2, Event:$3"

  [ "$1" = /var/www/html/.freepbx-known ] && [ "$3" = IN_CREATE ] && addRule
  [ "$1" = /var/www/html/.well-known/acme-challenge ] && [ "$3" = IN_CREATE ] && addRule
  [ "$1" = /var/www/html/.well-known/acme-challenge ] && [ "$3" = IN_DELETE ] && deleteRule

  echo "END Path:$1, File:$2, Event:$3"
  exit 0
}

[ "$1" = install ]    && install
[ "$1" = remove ]     && uninstall
[ "$1" = uninstall ]  && uninstall
[ "$1" = deleterule ] && deleteRule
[ "$1" = deleteRule ] && deleteRule
main "$@" 2>&1 | /usr/bin/logger -t "${me// /_}[$$]" 
