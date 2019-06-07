#! /bin/bash

#####################################################################
#                                                                   #
# Author:       Martin Boller                                       #
#                                                                   #
# Email:        martin                                              #
# Last Update:  2019-06-04                                          #
# Version:      1.01                                                #
#                                                                   #
# Changes:      Initial version, based on Alerta Vagrant (1.00)     #
#               Using systemd instead of corn for housekeeping      #
#               and heartbeats and heartbeat alerts                 #
#                                                                   #
#####################################################################


configure_locale() {
  echo -e "\e[32mconfigure_locale()\e[0m";
  echo -e "\e[36m-Configure locale (default:C.UTF-8)\e[0m";
  export DEBIAN_FRONTEND=noninteractive;
  sudo sh -c "cat << EOF  > /etc/default/locale
# /etc/default/locale
LANG=C.UTF-8
LANGUAGE=C.UTF-8
LC_ALL=C.UTF-8
EOF";
  update-locale;
  /usr/bin/logger 'Configured Locale' -t 'Alerta Server)';
}

configure_timezone() {
  echo -e "\e[32mconfigure_timezone()\e[0m";
  echo -e "\e[36m-Set timezone to Etc/UTC\e[0m";
  export DEBIAN_FRONTEND=noninteractive;
  sudo rm /etc/localtime;
  sudo sh -c "echo 'Etc/UTC' > /etc/timezone";
  sudo dpkg-reconfigure -f noninteractive tzdata;
  /usr/bin/logger 'Configured Timezone UTC' -t 'Alerta Server';
}

apt_install_prerequisites() {
    # Install prerequisites and useful tools
    export DEBIAN_FRONTEND=noninteractive;
    apt-get -y remove postfix*;
        sudo sync \
        && sudo apt-get update \
        && sudo apt-get -y upgrade \
        && sudo apt-get -y dist-upgrade \
        && sudo apt-get -y --purge autoremove \
        && sudo apt-get autoclean \
        && sudo sync;
        /usr/bin/logger 'install_updates()' -t 'Alerta Server';
    apt-get install -y whois build-essential devscripts git unzip apt-transport-https ca-certificates curl gnupg2 software-properties-common sudo dnsutils dirmngr --install-recommends;
    /usr/bin/logger 'Installed Prerequisites' -t 'Alerta Server)';
}

install_mongodb() {
    DEBIAN_FRONTEND=noninteractive apt-get -y install mongodb-server;
    grep -q smallfiles /etc/mongodb.conf || echo "smallfiles = true" | tee -a /etc/mongodb.conf;
    systemctl daemon-reload;
    systemctl restart mongodb;
    sudo sh -c "cat << EOF  >> /etc/environment
DATABASE_URL=mongodb://localhost:27017/monitoring
BASE_URL=/api
EOF";
    export DATABASE_URL=mongodb://localhost:27017/monitoring;
    /usr/bin/logger 'Installed MONGODB' -t 'Alerta Server)';
}

install_python3_pip() {
    echo "Installing Python3 pip";
    DEBIAN_FRONTEND=noninteractive apt-get -y install python3 python3-pip python3-dev python3-setuptools python3-venv libffi-dev;
    /usr/bin/logger 'Installed Python3 PIP' -t 'Alerta Server)';
}

install_alertaserver() {
    DATABASE_URL=mongodb://localhost:27017/monitoring;
    export DATABASE_URL=mongodb://localhost:27017/monitoring;

    id alerta || (groupadd alerta && useradd -g alerta alerta);
    cd /opt;
    python3 -m venv alerta;
    /opt/alerta/bin/pip install --upgrade pip wheel;
    /opt/alerta/bin/pip install alerta-server;
    /opt/alerta/bin/pip install alerta;
    mkdir /home/alerta/;
    chown -R alerta:alerta /home/alerta;
    sudo sh -c "cat << EOF  >> /etc/profile.d/alerta.sh
PATH=$PATH:/opt/alerta/bin
EOF";

    sync;

    sudo sh -c "cat << EOF  >> /etc/alertad.conf
DEBUG=False
TESTING=False
SECRET_KEY='$(< /dev/urandom tr -dc A-Za-z0-9_\!\@\#\$\%\^\&\*\(\)-+= | head -c 32)'
PLUGINS=['reject', 'blackout', 'slack']
DATABASE_URL='mongodb://localhost:27017/monitoring'
JSON_AS_ASCII=False
JSON_SORT_KEYS=True
JSONIFY_PRETTYPRINT_REGULAR=True
AUTH_REQUIRED = True
AUTH_PROVIDER = 'basic'
ADMIN_USERS = ['admin', 'alerta@example.org']
USER_DEFAULT_SCOPES = ['read', 'write:alerts']
ALLOWED_ENVIRONMENTS=['Production', 'Development', 'Testing']
LOG_HANDLERS = ['file']
LOG_FILE = '/var/log/alertad.log'
LOG_MAX_BYTES = 5*1024*1024  # 5 MB
LOG_BACKUP_COUNT = 2
LOG_FORMAT = 'json'
ALERT_TIMEOUT = 432000  # 5 days
HEARTBEAT_TIMEOUT = 7200  # 2 hours
EOF";

    sudo sh -c "cat << EOF > $HOME/.alerta.conf
[DEFAULT]
endpoint = http://localhost/api
EOF";
    /usr/bin/logger 'Installed Alerta Core' -t 'Alerta Server)';
}

install_alerta() {
    id alerta || (groupadd alerta && useradd -g alerta alerta);
    cd /opt;
    python3 -m venv alerta;
    /opt/alerta/bin/pip install --upgrade pip wheel;
    /opt/alerta/bin/pip install alerta;
    mkdir /home/alerta/;
    chown -R alerta:alerta /home/alerta;
}

install_alerta_nginx() {
    BASE_URL=/api;
    DATABASE_URL=mongodb://localhost:27017/monitoring
    export BASE_URL=/api;
    export DATABASE_URL=mongodb://localhost:27017/monitoring;
    DEBIAN_FRONTEND=noninteractive apt-get -y install nginx;
    /opt/alerta/bin/pip install uwsgi;
    mkdir /var/www/alerta/;
    touch /var/log/alertad.log;
    chmod 664 /var/log/alertad.log;
    sudo sh -c "cat << EOF  > /var/www/alerta/wsgi.py
from alerta import app
EOF";

   sudo sh -c "cat << EOF  > /etc/uwsgi.ini
[uwsgi]
chdir = /var/www/alerta
mount = /api=wsgi.py
callable = app
manage-script-name = true
env = BASE_URL=/api

master = true
processes = 5
logger = syslog:alertad

socket = /tmp/uwsgi.sock
chmod-socket = 664
uid = www-data
gid = www-data
vacuum = true

die-on-term = true
EOF";

    sync;

   sudo sh -c 'cat << EOF  > /etc/systemd/system/uwsgi.service
[Unit]
Description=uWSGI service

[Service]
ExecStart=/opt/alerta/bin/uwsgi --ini /etc/uwsgi.ini

[Install]
WantedBy=multi-user.target
EOF';

    sync;

cat >/etc/nginx/sites-enabled/default <<EOF
server {
        listen 80 default_server;
        listen [::]:80 default_server;

        location ${BASE_URL} { try_files \$uri @api; }
        location @api {
            include uwsgi_params;
            uwsgi_pass unix:/tmp/uwsgi.sock;
            proxy_set_header Host \$host:\$server_port;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        root   /var/www/alerta/;

        location / {
            try_files \$uri \$uri/ /index.html;
        }
}
EOF

    cd /tmp;
    wget -q -O - https://github.com/alerta/alerta-webui/releases/latest/download/alerta-webui.tar.gz | tar zxf -;
    cp -R /tmp/dist/* /var/www/alerta/;

sudo sh -c "cat << EOF  > /var/www/alerta/config.json
{\"endpoint\": \"${BASE_URL}\"} 
EOF";
    sync;
    systemctl enable uwsgi;
    systemctl start uwsgi;
    systemctl enable nginx;
    systemctl restart nginx;
    /usr/bin/logger 'Installed NGINX for Alerta' -t 'Alerta Server)';
}

configure_heartbeat_alert() {
    echo "Configure Heartbeat Alerts on Alerta Server";
    export DEBIAN_FRONTEND=noninteractive;
    id alerta || (groupadd alerta && useradd -g alerta alerta);
    mkdir /home/alerta/;
    chown -R alerta:alerta /home/alerta;
    # Create Alerta configuration file
        sudo sh -c "cat << EOF  >  /home/alerta/.alerta.conf
[DEFAULT]
endpoint = http://cetus.bollers.dk/api
key = CHANGEME
EOF";

    # Create  Service
    sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-heartbeats-alert.service
[Unit]
Description=Alerta Heartbeats Alert service
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Service]
User=alerta
Group=alerta
ExecStart=-/opt/alerta/bin/alerta --config-file /home/alerta/.alerta.conf heartbeats --alert --severity critical
WorkingDirectory=/home/alerta

[Install]
WantedBy=multi-user.target
EOF";

   sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-heartbeats-alert.timer
[Unit]
Description=Checks heartbeats and alerts if timed out
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Timer]
OnUnitActiveSec=120s
Unit=alerta-heartbeats-alert.service

[Install]
WantedBy=multi-user.target
EOF";

# Housekeeping Alerta
    # Create  Service
    sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-housekeeping.service
[Unit]
Description=Alerta Housekeeping service
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Service]
User=alerta
Group=alerta
ExecStart=-/opt/alerta/bin/alerta --config-file /home/alerta/.alerta.conf housekeeping
WorkingDirectory=/home/alerta

[Install]
WantedBy=multi-user.target
EOF";

   sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-housekeeping.timer
[Unit]
Description=Checks heartbeats and alerts if timed out
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Timer]
OnUnitActiveSec=120s
Unit=alerta-housekeeping.service

[Install]
WantedBy=multi-user.target
EOF";
    systemctl daemon-reload;
    systemctl enable alerta-heartbeats-alert.timer;
    systemctl enable alerta-heartbeats-alert.service;
    systemctl start alerta-heartbeats-alert.timer;
    systemctl start alerta-heartbeats-alert.service;
    systemctl enable alerta-housekeeping.timer;
    systemctl enable alerta-housekeeping.service;
    systemctl start alerta-housekeeping.timer;
    systemctl start alerta-housekeeping.service;
    /usr/bin/logger 'Configured heartbeat alerts service' -t 'Alerta Server)';
}

configure_heartbeat() {
    echo "Configure Heartbeat Alerts on Alerta Server";
    export DEBIAN_FRONTEND=noninteractive;
    id alerta || (groupadd alerta && useradd -g alerta alerta);
    mkdir /home/alerta/;
    chown -R alerta:alerta /home/alerta;
    # Create Alerta configuration file
    sudo sh -c "cat << EOF  >  /home/alerta/.alerta.conf
[DEFAULT]
endpoint = http://cetus.bollers.dk/api
key = CHANGEME
EOF";

    # Create  Service
    sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-heartbeat.service
[Unit]
Description=Alerta Heartbeat service
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Service]
User=alerta
Group=alerta
ExecStart=-/opt/alerta/bin/alerta --config-file /home/alerta/.alerta.conf heartbeat --timeout 120
#Restart=always
WorkingDirectory=/home/alerta

[Install]
WantedBy=multi-user.target
EOF";

   sudo sh -c "cat << EOF  >  /lib/systemd/system/alerta-heartbeat.timer
[Unit]
Description=sends heartbeats to alerta every 60 seconds
Documentation=https://http://docs.alerta.io/en/latest/deployment.html#house-keeping
Wants=network-online.target

[Timer]
OnUnitActiveSec=60s
Unit=alerta-heartbeat.service

[Install]
WantedBy=multi-user.target
EOF";
    systemctl daemon-reload;
    systemctl enable alerta-heartbeat.timer;
    systemctl enable alerta-heartbeat.service;
    systemctl start alerta-heartbeat.timer;
    systemctl start alerta-heartbeat.service;
    /usr/bin/logger 'Configured heartbeat service' -t 'Alerta Server)';
}


#################################################################################################################
## Main Routine                                                                                                 #
#################################################################################################################

main() {
    # Core elements, always installs
    install_python3_pip;
    configure_locale;
    configure_timezone;

    # Server specific elements
    if [ "$HOSTNAME" = "alertaserver" ]; 
        then
        # Installation of specific components
        install_alertaserver;
        install_alerta_nginx;

        # Configuration of installed components
        configure_heartbeat_alert;
    fi

    if [ "$HOSTNAME" = "otherserver" ]; 
        then
        # Installation of specific components
        install_alerta;
        
        # Configuration of installed components
        configure_heartbeat;
    fi
}

main;

exit 0
