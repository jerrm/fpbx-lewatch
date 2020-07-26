# fpbx-lewatch
## Purpose
Temporarily allow http connections for LetsEncrypt updates.

## What this does
Opens iptables http access for the few seconds needed during LetsEncrypt
generation/renewal.  LetsEncrypt validation requests can now come from anywhere
 and previous whitelist methods no longer work.

## Use this...
If you manage your own iptables rules and are **_not_** using FreePBX Firewall
module (firewall is not installed or is disabled).  Installing should allow
Certificate Manager LetsEncrypt generation and updates to "just work" even if
iptables normally blocks http traffic.

## Don't use this...
If using FreePBX firewall module.  As of June 2020, FreepBX with recent
Certman and Firewall module updates opens up the firewall automatically.

## How it works
A file watch service monitors the folders FreePBX uses for LetsEncrypt
updates.  When an update is detected, the service opens up http access in
iptables, then closes access when the update files are deleted.  The update
process generally takes about 5-10 seconds per certificate.

The http pinhole is accomplished by inserting a single rule allowing http
access.  The rule is automatically deleted once the update is complete.

Only http port 80 is opened. At no point is iptables disabled or restarted.
All other existing iptables rules remain active.

A 60 second timeout makes sure the door is closed if the LetsEncrypt update
process hangs for some reason.

A nightly cron job is setup to reload Apache if its certificate was updated.

## Installing
Save the _lewatch.sh_ script to wherever you want it on your system.  To
activate the service run:
```
lewatch.sh install
```

To remove the service run:
```
lewatch.sh remove
```

## Changes to system
No pre-existing config files are modified by this script.

### Sangoma Distro
If installled under the Sangoma Distro, the script uses the Distro's existing
incrond 0.5._10_ to watch for the file changes associated with a LetsEncrypt
update.  No new packages are installed.  One additional config file is added
to /etc/incron.d.

### CentOS, Debian, Ubuntu, etc..
For all other distributions, the script uses [_direvent_](https://www.gnu.org.ua/software/direvent/)
to monitor file system changes.

The incrond version in the CentOS7 EPEL repo and recent Debian derivatives
is 0.5._12_. Unfortunately, incrond 0.5.12 has some pretty nasty bugs.  The bugs
would not directly impact this script's functionality, but they are easy to
trigger. It is best not to rely on the 0.5.12 version.

If a working _direvent_ is found it will be used.  If not found, the  script
builds and installs [_direvent_ 5.2](https://www.gnu.org.ua/software/direvent/)
to monitor file system changes.

#### Why not use the Linux distribution's _direvent_ package?
CentOS doesn't have a _direvent_ package. The git version built is a few commits
ahead of the official 5.2 release and includes fixes worth the build time.

Any packages installed to facilitate building _direvent_ are removed
automatically. The net impact on the running system should be minimal.

_If the distribution's direvent package is preferred, install it first._

## What about Apache?
If using the Sangoma Distro, select the proper certificate under
_Admin->System Admin->HTTPS Setup->Settings_ and FreePBX will automatically
reload the Apache config as needed.

FreePBX does not automatically reload Apache if not using the official Distro.

Therefore, this script schedules a nightly cron job to update the running
Apache server.  The cron job checks the current in-use certificate against
latest version on disk and reloads Apache if needed.

_To disable auto updating, delete the file /etc/cron.d/lewatch-reload-apache._

### Apache Certificate Location
The script assumes Apache will use the certificate selected as "default" in
the certman GUI.  FreePBX always copies the "default" cert to the location
/etc/asterisk/keys/integration, making it simple to reference regardless
of host name.

_If another certificate is desired, edit the script pemPath variable._

Parsing any potential Apache configuration changes is beyond scope of the
script.  Updating the Apache config files to use the certman LetsEncrypt
certificate is left to the user.

Sample code to update default CentOS7 and Debian configs:
1. *CentOS 7*
   ```
   # if mod_ssl is not already enabled then install it
   yum -y install mod_ssl
   
   # point SSLCertificateFile to the FreePBX "default" certificate full chain pem file
   sed  -i 's|^SSLCertificateFile .*$|SSLCertificateFile /etc/asterisk/keys/integration/certificate.pem|g' /etc/httpd/conf.d/ssl.conf
   
   # comment out the SSLCertificateKeyFile line as it isn't needed
   sed  -i '/^SSLCertificateKeyFile/ s/^#*/#/' /etc/httpd/conf.d/ssl.conf
   
   # restart apache to pick up our changes
   systemctl restart httpd

   ```
2. *Debian Buster*
   ```
   # point SSLCertificateFile to the FreePBX "default" certificate full chain pem file
   sed -i '/^\s*SSLCertificateFile\s/ s|SSLCertificateFile\s.*$|SSLCertificateFile /etc/asterisk/keys/integration/certificate.pem|g' /etc/apache2/sites-available/default-ssl.conf

   # comment out the SSLCertificateKeyFile line as it isn't needed
   sed -i '/^\s*SSLCertificateKeyFile/ s/SSLCertificateKeyFile/#SSLCertificateKeyFile/' /etc/apache2/sites-available/default-ssl.conf

   # enable ssl
   a2enmod ssl
   a2ensite default-ssl

   # restart apache to pick up our changes
   systemctl restart apache2
   ```


## Does it have to open all http access?
The default exposure is minimal. The http pinhole is open for less than 10
seconds in most cases, and then only once every 60 days.  

The script as published is intended  to "just work" for most any iptables rule
set.  It can certainly be tweaked to be more restrictive, but it is difficult
to be more restrictive in a generic way. Some user customization is required.

To mimic the Sangoma Distro's approach of limiting to access only to the
LetsEncrypt web folders:

1. Add the following rules to create add an lefilter chain to your iptables rules
   ```
   iptables -N lefilter
   iptables -A lefilter -m state --state NEW -j ACCEPT
   iptables -A lefilter -m string --string "GET /.well-known/acme-challenge/" --algo kmp --from 52 --to 53 -j ACCEPT
   iptables -A lefilter -m string --string "GET /.freepbx-known" --algo kmp --from 52 --to 53 -j ACCEPT
   iptables -A lefilter -j DROP
   ```
2. Change the `rule` variable in the script from:
   ```
   rule="INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment $serviceName"
   ```
   to:
   ```
   rule="INPUT -p tcp --dport 80 -j lefilter -m comment --comment $serviceName"
   ```

