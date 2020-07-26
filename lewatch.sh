#!/bin/bash

fullme="$(realpath -- "$0")"
baseme="$(basename -- "$0")"
me="${baseme%.*}"

serviceName=${me// /_}
reloadHour=03
sslPort=443
timeout=60

# iptables rule to insert
rule="INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment $serviceName"

# the reload funtion compares the running Apache cert to the specified cert
# and reloads Apache if needed.
#
# set below to an appropriate file or glob pattern
#   ie: to use the certificate flagged as default in certman use:
#         pemPath="/etc/asterisk/keys/integration/certificate.pem"
#
#       to specify www.mydomain.com as the apache cert use:
#         pemPath=/etc/asterisk/keys/www.mydomain.com.pem
#
#       or a glob pattern for the cert as stored under /etc/asterisk/keys:
#         pemPath=/etc/asterisk/keys/www.mydomain.com*
#
#	or the cert specific subfolder:
#         pemPath=/etc/asterisk/keys/www.mydomain.com/
#
#       the glob and folder options are mainly to facilitate copying the files
#       using the pemCopyDest option below
#
pemPath="/etc/asterisk/keys/integration/certificate.pem"

# set the path below if the updated cert files should be copied to another
# location for apache.
#
# if pemPath is a single file, only the specified file will be copied.
#
# if pemPath is a directory, all files in the directory will be copied.
#
# if pemPath is a glob pattern, ie:/etc/asterisk/keys/www.mydomain.com* then
# all files matching the pattern will be copied.
#
pemCopyDest=""

# process to run after a reload, no parameters are passed but environment is
# populated with:
#   wwwService apacheEndDate pemEndDate pemPath pemFile pemCopySource
#   pemCopyDest serviceName watcherService
#
updateHook=""

[[ "$(</etc/os-release)" =~ Sangoma ]] && isDistro=true || isDistro=false

# file system watcher service:
# use incron for the distro, otherwise use direvent.
# distro has (and heavily relies on) incron v0.5.10.
# current CentOS EPEL & recent Debian derivatives have 0.5.12.
# 0.5.12 has some nasty bugs, so use direvent.
$isDistro && watcherService=incron || watcherService=direvent

# uncomment/edit below to force watcher service to incron/direvent
#watcherService=incron


main() {
  local -l command="$1"
  case "$command" in
    install)
      install;;
    install-all)
      install all;;
    uninstall|remove)
      uninstall;;
    deleterule)
      deleteRule;;
    reload)
      reloadApache 2>&1 | log;;
    *)
      [ -t 1 ] && {
        echo "nothing to do -$1- not a valid command" | log
        return 0
      }
      doEvent "$@" 2>&1 | log & ;;
  esac
}

doEvent() {
  # parse incron command line parameters/direvent environment variables
  local eventPath="${1-$PWD}"
  local eventFile="${2-$DIREVENT_FILE}"
  local event="${3-${DIREVENT_SYSEV_NAME}}"; event="${event##*IN_}"

  echo "START Path:$eventPath, File:$eventFile, Event:$event"
  [ "$eventPath" = /var/www/html/.freepbx-known ] && [ "$event" = CREATE ] && addRule
  [ "$eventPath" = /var/www/html/.well-known/acme-challenge ] && [ "$event" = CREATE ] && addRule
  [ "$eventPath" = /var/www/html/.well-known/acme-challenge ] && [ "$event" = DELETE ] && deleteRule
  echo "END Path:$eventPath, File:$eventFile, Event:$event"
}

addRule() {
  echo "${FUNCNAME[0]}: $rule"
  iptables -w -C $rule 2>/dev/null || iptables -w -I $rule
  sleep $timeout
  deleteRule
}

deleteRule() {
  while iptables -w -C $rule 2>/dev/null; do
    echo "${FUNCNAME[0]}: $rule"
    iptables -w -D $rule
    sleep 0.1
  done
}

log() {
  local out=""
  [ -t 1 ] && out="-s"
  /usr/bin/logger $out -t "$serviceName[$$]"
}

reloadApache() {
  local wwwService apacheEndDate pemEndDate pemFile pemCopySource
  wwwService="$(netstat -lnp | grep -E "$sslPort\s.*/(apache2|httpd)")"
  wwwService=${wwwService##*/}
  wwwService=${wwwService%% *}

  [ "$wwwService" = "" ] && {
    echo "${FUNCNAME[0]}: abort - apache not listening on sslPort $sslPort"
    return 1
  }

  # if path ends in "/*" assume it is a cert folder and remove the "*"
  [[ "$pemPath" = */\* ]] &&  pemPath="${pemPath%?}"

  if [ "$pemPath" = "$(echo $pemPath)" ]; then
    # no glob expansion, assume file or directory
    if [ -d "$pemPath" ]; then
      [[ "$pemPath" != */ ]] && pemPath="${pemPath}/"
      pemFile="$(echo ${pemPath}cert*.pem)"
      pemCopySource="${pemPath}*"
    else
      pemFile="$pemPath"
      pemCopySource="$pemPath"
    fi
  else
    pemFile="$(echo ${pemPath}.pem)"
    pemCopySource="$pemPath"
  fi

  [ ! -f "$pemFile" ] && {
    echo "${FUNCNAME[0]}: abort - pemFile invalid - $pemFile"
    return 1
  } || {
    echo "${FUNCNAME[0]}: using pemFile $pemFile"
  }

  apacheEndDate="$(echo | openssl s_client -showcerts -connect localhost:$sslPort 2>/dev/null | openssl x509 -inform pem -noout -enddate)"
  pemEndDate=$(openssl x509 -in $pemFile -noout -enddate)

  [ "$apacheEndDate" != "$pemEndDate" -a "$apacheEndDate" != "" -a "$wwwService" != "" ] && {
    [ -d "$pemCopyDest" ] && ( IFS=''; cp -vb $pemCopySource $pemCopyDest; )
    echo "${FUNCNAME[0]}: reloading $wwwService, apache $apacheEndDate, pemFile $pemEndDate"
    systemctl reload $wwwService
    [ -x $updateHook ] && {
      export wwwService apacheEndDate pemEndDate pemFile pemCopySource pemCopyDest pemPath serviceName watcherService
      $updateHook
    }
    return 0
  }

  echo "${FUNCNAME[0]}: nothing to do, service $wwwService, port $sslPort, apache $apacheEndDate, pemFile $pemEndDate"
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

  rm -vf "/etc/incron.d/$serviceName" \
         "/etc/$serviceName.conf" \
         "/etc/cron.d/$serviceName-reload-apache"

  install_$watcherService $1 || {
    echo -e "\n\n\n\n"
    echo "Installing watcher failed. Running uninstall to clean up unwanted files."
    uninstall
    return 1
  }

  echo -e "\n\n\n\n"
  $isDistro || {
    # schedule apache reload if not using the Distro (sysadmin does it automatically on distro)
    echo "$(($RANDOM % 40 + 10)) $reloadHour * * * root $(printf %q "$fullme") reload" > "/etc/cron.d/$serviceName-reload-apache"
    grep -rq "$pemPath" /etc/httpd/* 2>/dev/null || grep -rq "$pemPath" /etc/apache2/* 2>/dev/null ||
      cat <<- _EOF_
	=======================
	==     ATTENTION     ==
	=======================

	Apache config does not appear to use the FreePBX default certificate.

	  * If Apache does not yet https enabled, setup as outlined in the README.

	  * If Apache is not using the the FreePBX default certificate, edit the
	    script "pemPath=" line to reference the appropriate pem file under
	    /etc/asterisk/keys.

	  * If Apache is not using ANY FreePBX LetsEncrypt certificate, remove
	    the file /etc/cron.d/$serviceName-reload-apache to avoid unnecessary
	    (but harmless) reloads.

	_EOF_
  }
  echo "$serviceName Install Complete"
}

install_incron() {
  # install incrond
  local incrond
  [ -f /etc/redhat-release ] && { incrond=incrond; yum -y install incron; } || { incrond=incron; apt-get -y install incron; }

  # setup le watcher
  {
    echo "/var/www/html/.well-known/acme-challenge IN_CREATE,IN_DELETE $(printf %q "$fullme") "'$@ $# $% $&'
    echo "/var/www/html/.freepbx-known IN_CREATE,IN_DELETE $(printf %q "$fullme") "'$@ $# $% $&'
  } > "/etc/incron.d/$serviceName"

  systemctl enable $incrond
  systemctl restart $incrond
  systemctl is-active $incrond &>/dev/null
}

install_direvent() {
  local installList removeList lastTransID newTransID disableMI

  # install direvent if not present
  which direvent || {
    # install build requirements
    if [ -f /etc/redhat-release ]; then
      lastTransID=$(yum history info | sed -n -e 's/^Transaction ID : //p')
      installList="autoconf automake bison flex gcc gettext-devel git m4 make texinfo rsync"
      yum -q -y --skip-broken install $installList
      newTransID=$(yum history info | sed -n -e 's/^Transaction ID : //p')
    else
      installList="autoconf automake autopoint bison flex g++ git m4 make rsync texinfo"
      removeList=$(apt-get -s --no-install-recommends install $installList | grep ^Inst | cut -d" " -f2)
      echo Installing $installList
      apt-get -y --no-install-recommends install $installList
    fi

    # makeinfo requires powertools repo on CentOS8.
    # more trouble than it's worth, so skip if it's missing...
    which makeinfo || disableMI="MAKEINFO=true"

    # build/install direvent
    cd /tmp
    rm -rf direvent
    git clone git://git.gnu.org.ua/direvent.git &&
    cd direvent &&
    # checkout a known stable version(v5.2 + a couple of fixes - 2020-07-08 10:20:40)
    git checkout 81dc61553e7063c4fad4c2265c9defa801ef6064 &&
    ./bootstrap &&
    ./configure --quiet --sysconfdir=/etc --prefix=/usr &&
    if [ "$1" = all ]; then
      make --quiet install-strip V=1 $disableMI
    else
      make --quiet V=1
      make --quiet -C src install-strip
    fi &&
    cd ../
    rm -rf direvent

    # remove any packages we had to install for build
    if [ -f /etc/redhat-release ]; then
      [ "$lastTransID" != "$newTransID" ] && yum -q -y history undo $newTransID && yum clean all
    else
      apt-get -y purge $removeList
      apt-get -y clean && apt-get -y autoclean
    fi
  }

  # remove any packages we had to install for build
  if [ -f /etc/redhat-release ]; then
    [ "$lastTransID" != "$newTransID" ] && yum -q -y history undo $newTransID && yum clean all
  else
    apt-get -y purge $removeList
    apt-get -y clean && apt-get -y autoclean
  fi

  # set up systemd service
  cat <<- _EOF_ > /etc/systemd/system/$serviceName.service
	[Unit]
	Description=Monitor FreePBX web folders for LetsEncrypt updates

	[Service]
	RuntimeDirectory=$serviceName

	# be paranoid - delete the iptables rule
	ExecStartPre="$fullme" deleterule
	ExecStopPost="$fullme" deleterule

	ExecStart=@/usr/bin/direvent $serviceName --pidfile=/var/run/$serviceName/$serviceName.pid --foreground /etc/$serviceName.conf

	[Install]
	WantedBy=multi-user.target
	_EOF_

  # install config file...
  # direvent 5.1 and the git build could use a single watcher block with
  # multiple path statements, unfortunately direvent 5.2 in Ubuntu 20+ and
  # Debian 11+ segfault during shutdown when a watcher has multiple paths
  cat <<- _EOF_ > /etc/$serviceName.conf
	# Watch FreePBX web folders for LetsEncrypt activites
	watcher {
	  path /var/www/html/.freepbx-known;
	  event (create,delete);
	  command "$(printf %q "$fullme" | sed 's/\\/\\\\/g')";
	}

	watcher {
	  path /var/www/html/.well-known/acme-challenge;
	  event (create,delete);
	  command "$(printf %q "$fullme" | sed 's/\\/\\\\/g')";
	}

	syslog {
	  facility local0;
	  print-priority yes;
	}
	_EOF_

  # enable and start service
  systemctl daemon-reload
  systemctl enable $serviceName
  systemctl restart $serviceName
  systemctl is-active $serviceName &>/dev/null
}

uninstall() {
  local incrond
  deleteRule
  [ -f /etc/redhat-release ] && incrond=incrond || incrond=incron
  systemctl is-active $serviceName &>/dev/null && systemctl stop $serviceName
  chattr -i /var/www/html/.well-known/acme-challenge/.nodelete \
            /var/www/html/.freepbx-known/.nodelete

  rm -vf "/etc/incron.d/$serviceName" \
         "/etc/$serviceName.conf" \
         "/etc/cron.d/$serviceName-reload-apache" \
         "/etc/systemd/system/$serviceName.service"
	 /var/www/html/.well-known/acme-challenge/.nodelete \
         /var/www/html/.freepbx-known/.nodelete
  systemctl daemon-reload
  systemctl is-enabled $incron &>/dev/null && systemctl restart $incron
}

main "$@"
