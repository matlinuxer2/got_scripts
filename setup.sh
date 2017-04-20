#!/usr/bin/env bash

function setup_system(){
emerge --sync
eselect news read

# to fix systemd deps
eselect profile set default/linux/amd64/13.0/systemd
emerge --deselect sys-fs/udev

[ -e /etc/portage/sets ] || install -d /etc/portage/sets
cat <<EOF > /etc/portage/sets/got
app-misc/screen[pam]
app-editors/vim[acl,nls]
www-servers/apache[threads]
dev-db/mariadb
dev-lang/php[cgi,curl,fpm,gd,mysql,mysqli,sqlite,truetype,zip]
sys-apps/systemd
net-misc/openssh
dev-vcs/git
EOF

[ -e /etc/portage/env ] || install -d /etc/portage/env
cat <<EOF > /etc/portage/env/got.conf
APACHE2_MODULES="\$APACHE2_MODULES http2 macro proxy actions ssl rewrite alias proxy_fcgi access_compat"
APACHE2_MPMS="event"
EOF

cat <<EOF > /etc/portage/package.env
www-servers/apache got.conf
EOF

opts="--autounmask-write"
opts="$opts --quiet"
opts="$opts --noreplace"

emerge $opts @got --verbose --pretend --tree
read -p "Press <Enter> to continue..."
emerge $opts @got
read -p "Press <Enter> to continue..."
FEATURES=protect-owned emerge $opts --update --newuse --deep @world
read -p "Press <Enter> to continue..."
emerge $opts --depclean --pretend
read -p "Press <Enter> to continue..."
emerge $opts --depclean
}


function setup_mysql(){
qlist -Iv mariadb
if [ $? -eq 0 ] ; then
    [ -e "/var/lib/mysql/mysql/user.MYD" ] || {
        dbpass=$(uuidgen)

        cat <<EOF > /root/.my.cnf
[client]
password = $dbpass
EOF

        echo "password = $dbpass" > /etc/mysql/debian.cnf
        emerge --config dev-db/mariadb
        [ -e /root/.my.cnf ] && rm /root/.my.cnf
    }
fi
}

function setup_apache(){
cat <<EOF > /etc/apache2/modules.d/99_got.conf
ServerName localhost
Listen 80
Listen 443

Alias /phpmyadmin /usr/share/phpmyadmin
<Directory /usr/share/phpmyadmin>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
    DirectoryIndex index.php
</Directory>

<IfModule http2_module>
    Protocols h2 h2c http/1.1
    H2Push          on
    H2PushPriority  *                       after
    H2PushPriority  text/css                before
    H2PushPriority  image/jpeg              after   32
    H2PushPriority  image/png               after   32
    H2PushPriority  application/javascript  interleaved
</IfModule>
EOF

cat <<EOF > /etc/apache2/vhosts.d/99_www.gentoo.tw.conf
<macro theVHost \$name \$docroot \$admin>
        ServerAdmin \$admin
        ServerName \$name
        DocumentRoot \$docroot
        <Directory \$docroot>
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
                DirectoryIndex index.html index.php
        </Directory>

        ErrorLog /var/log/apache2/error-\$name.log
        CustomLog /var/log/apache2/access-\$name.log combined
        <IfModule mod_proxy_fcgi.c>
            ProxyPassMatch ^/phpmyadmin/(.*\\.php(/.*)?)$ fcgi://127.0.0.1:9000/usr/share/phpmyadmin/\$1
            ProxyPassMatch ^/(.*\\.php(/.*)?)$ fcgi://127.0.0.1:9000/\$docroot/\$1
        </IfModule>
</macro>
<macro theVHostComb \$name \$docroot \$admin>
    <VirtualHost *:80>
        Use theVHost \$name \$docroot \$admin
    </VirtualHost>
    #<VirtualHost *:443>
    #    Use theVHost \$name \$docroot \$admin
    #    SSLEngine on
    #    SSLCertificateFile    /etc/ssl/certs/ssl-cert-\$name.pem
    #    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-\$name.key
    #</VirtualHost>
</macro>

Use theVHostComb localhost       /var/www/localhost/htdocs               root@localhost
Use theVHostComb www.gentoo.tw   /var/www/vhost/www.gentoo.tw/httpdocs   service@gentoo.tw
Use theVHostComb forum.gentoo.tw /var/www/vhost/forum.gentoo.tw/httpdocs service@gentoo.tw
Use theVHostComb wiki.gentoo.tw  /var/www/vhost/wiki.gentoo.tw/httpdocs  service@gentoo.tw
EOF

    [ -e "/run/apache_ssl_mutex" ] || { install -d "/run/apache_ssl_mutex"; }

    extra_opts="-D MACRO -D PHP -D PROXY"
    cat /etc/conf.d/apache2  | grep -e '^\s*APACHE2_OPTS' | grep -e "$extra_opts"
    if [ $? -ne 0 ]; then
        sed -i /etc/conf.d/apache2 -e "s/\(^\s*APACHE2_OPTS.*\)\(\"\s*\)$/\1 $extra_opts \2/g"
    fi

    httpdocs_dirs=""
    httpdocs_dirs="$httpdocs_dirs /var/www/vhost/www.gentoo.tw/httpdocs"
    httpdocs_dirs="$httpdocs_dirs /var/www/vhost/forum.gentoo.tw/httpdocs"
    httpdocs_dirs="$httpdocs_dirs /var/www/vhost/wiki.gentoo.tw/httpdocs"
    for ff in $httpdocs_dirs
    do

        [ -e "$ff" ] || {
            install -d "$ff"
            chown nobody:apache "$ff"
        }
    done
}

function cmd_make_letsencrypt(){ # 取得 Let's Encrypt 憑證
    local DOMAIN="$1"
    shift;
    local DN_SANS="$@"
    local binGETSSL="/usr/local/bin/getssl"
    local srcGETSSL="https://raw.githubusercontent.com/srvrco/getssl/master/getssl"
    local dirGETSSL="/root/.getssl/$DOMAIN"
    local cfgGETSSL="$dirGETSSL/getssl.cfg"

    [ -n "$DOMAIN" ] || { die "Domain not found"; }

    [ -e "$binGETSSL" ] || {
        curl -s "$srcGETSSL" > "$binGETSSL";
        chmod 700 "$binGETSSL";
    }

    ACL_SANS=""
    for xx in $DN_SANS; do
        [ -n "$xx" ] && {
            ACL_SANS="$ACL_SANS '/var/www/vhosts/$DOMAIN/httpdocs/.well-known/acme-challenge'"
        }
    done

    install -vD /dev/null $cfgGETSSL
    cat > $cfgGETSSL <<EOD
CA="https://acme-v01.api.letsencrypt.org"
ACCOUNT_KEY_LENGTH=4096
PRIVATE_KEY_ALG="rsa"
#RENEW_ALLOW="14"
SERVER_TYPE="https"
CHECK_REMOTE="true"
SANS=$DN_SANS
ACL=('/var/www/vhosts/$DOMAIN/httpdocs/.well-known/acme-challenge' $ACL_SANS )
EOD

    $binGETSSL -d "$DOMAIN"

    local keyDST="/etc/ssl/private/ssl-cert-${DOMAIN}.key"
    local pemDST="/etc/ssl/certs/ssl-cert-${DOMAIN}.pem"

    [ -e "$dirGETSSL/${DOMAIN}.key" ] && install -D "$dirGETSSL/${DOMAIN}.key" "$keyDST"
    [ -e "$dirGETSSL/${DOMAIN}.crt" ] &&  {
        install -vD /dev/null            "$pemDST"
        cat "$dirGETSSL/${DOMAIN}.crt" >> "$pemDST"

        [ -e "$dirGETSSL/chain.crt" ] && {
            cat "$dirGETSSL/chain.crt"     >> "$pemDST"
        }
    }

    local redundant_path="/var/www/vhosts/$DOMAIN/httpdocs/.well-known/"

    [ -e "$redundant_path" ] && { rm -rvf "$redundant_path"; }
}

function setup_phpmyadmin(){
    src_url="https://www.adminer.org/latest.php"

    [ -d "/usr/share/phpmyadmin" ] || {
        install -d "/usr/share/phpmyadmin"
        curl -s -L $src_url > "/usr/share/phpmyadmin/index.php"
    }
}

function setup_timezone(){
    echo "Asia/Taipei" > /etc/timezone
    ln -sf /usr/share/zoneinfo/`cat /etc/timezone` /etc/localtime
}

function setup_service(){
    systemctl enable sshd
    systemctl enable apache2
    systemctl enable mysqld
    systemctl enable php-fpm@7.0
}

setup_system
setup_mysql
setup_apache
setup_phpmyadmin
setup_timezone
setup_service
