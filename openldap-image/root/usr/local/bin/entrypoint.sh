#!/bin/bash
set -e
set -o pipefail

# The sladp executable
EXE="/usr/sbin/slapd"

# Directory where slapd configuration will be stored
# Will be persistent (mounted from the host)
CONFIG_DIR="/etc/openldap/slapd.d"

# Log level. cannot be empty (at least: 32768)
LOG_LEVEL=2024

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192

mkdir -p /run/slapd

if [ -z "$SLAPD_PASSWORD_FILE" ]; then
    echo ">>> SLAPD_PASSWORD_FILE must be set so the initial admin account is created"
    exit 1
fi

if [ -z "$SLAPD_DOMAIN" ]; then
    echo ">>> SLAPD_DOMAIN must be set with the initial domain name"
    exit 1
fi

if [ -z "$SLAPD_ORGANIZATION" ]; then
    SLAPD_ORGANIZATION="SUSE"
fi

if [ -n "$SLAPD_TLS_ENABLED" ]; then
    LDAPS_URI="ldaps://"
fi

dc_string=""

IFS="."; declare -a dc_parts=($SLAPD_DOMAIN); unset IFS

for dc_part in "${dc_parts[@]}"; do
    dc_string="$dc_string,dc=$dc_part"
done

if [ -z "$SLAPD_ADMIN_USER" ] ; then
    SLAPD_ADMIN_USER="cn=admin,${dc_string:1}"
fi

IFS=","; declare -a admin_user_parts=($SLAPD_ADMIN_USER); unset IFS

base_string="BASE ${dc_string:1}"
suffix_string="suffix \"${dc_string:1}\""
rootdn_string="rootdn \"${SLAPD_ADMIN_USER}\""

password=`cat $SLAPD_PASSWORD_FILE`
password_hash=`slappasswd -s "${password}"`
rootpwd_string="rootpw ${password_hash}"

# slapd can be configured with 'slapd.conf' or with a 'slapd.d'
# directory: we will use the directory, created from a `slapd.ldif`
# file.
rm -f /etc/openldap/slapd.conf

# add some presets so ldapseach can be easily used...
cat >/etc/openldap/ldap.conf <<EOF
HOST             admin
TLS_CACERT       /etc/openldap/pki/ca.crt
TLS_REQCERT      allow
EOF

if [ -f /var/lib/ldap/data.mdb ]; then
    echo ">>> Configuration and database already present"
else
    echo ">>> Perform first start configuration"

    # populate initial schema

    echo ">>> Creating the slapd.ldif file"
    cat >/etc/openldap/slapd.ldif <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
#
#
# Define global ACLs to disable default read access.
#
olcArgsFile: /run/slapd.args
olcPidFile: /run/slapd.pid
#
EOF

    if [ ! -z "$SLAPD_TLS_ENABLED" ]; then
        echo ">>> Enabling TLS support"
        cat >>/etc/openldap/slapd.ldif <<EOF
olcTLSCipherSuite: HIGH:!SSLv3:!SSLv2:!ADH
olcTLSCACertificateFile: /etc/openldap/pki/ca.crt
olcTLSCertificateFile: /etc/openldap/pki/openldap.crt
olcTLSCertificateKeyFile: /etc/openldap/pki/openldap.pem

EOF
    fi

    cat >>/etc/openldap/slapd.ldif <<EOF
#
# Load dynamic backend modules:
#
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /usr/lib64/openldap
olcModuleload: back_mdb.la

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/ppolicy.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif
include: file:///etc/openldap/schema/openldap.ldif
include: file:///etc/openldap/schema/nis.ldif
include: file:///etc/openldap/schema/misc.ldif

# Frontend settings
#
dn: olcDatabase=frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: frontend
olcAccess: {0}to dn.base="" by * read
olcAccess: {1}to dn.base="cn=Subschema" by * read
olcAccess: {2}to attrs=userPassword by anonymous auth by dn="${SLAPD_ADMIN_USER}" write by * none
olcAccess: {3}to attrs=mail by self read by users read by * none
olcAccess: {4}to * by * none
#
# Sample global access control policy:
#	Root DSE: allow anyone to read it
#	Subschema (sub)entry DSE: allow anyone to read it
#	Other DSEs:
#		Allow self write access
#		Allow authenticated users read access
#		Allow anonymous users to authenticate
#
#olcAccess: to dn.base="" by * read
#olcAccess: to dn.base="cn=Subschema" by * read
#olcAccess: to *
#	by self write
#	by users read
#	by anonymous auth
#
# if no access controls are present, the default policy
# allows anyone and everyone to read anything but restricts
# updates to rootdn.  (e.g., "access to * by * read")
#
# rootdn can always read and write EVERYTHING!
#

dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcSuffix: ${dc_string:1}
olcRootDN: ${SLAPD_ADMIN_USER}
olcRootPW: ${password_hash}
olcDbDirectory: /var/lib/ldap
olcDbIndex: default pres,eq
olcDbIndex: uid
olcDbIndex: cn,sn,mail pres,eq,sub
olcDbIndex: objectClass eq
EOF

    if [ ! -z "$SLAPD_TLS_ENABLED" ]; then
        cat >>/etc/openldap/slapd.ldif <<EOF
olcSecurity: tls=1
EOF
    fi

    echo ">>> Configuring slapd from:"
    echo ">>> -------------------------------"
    cat /etc/openldap/slapd.ldif
    echo ">>> -------------------------------"
    echo
    slapadd -n 0 -F $CONFIG_DIR -l /etc/openldap/slapd.ldif

    echo ">>> Configuring admin user access..."
    admin_cn=`echo ${admin_user_parts[0]} | sed 's|cn=||g'`
    echo ">>> Admin user: $admin_cn"

    cat >/tmp/ldif <<EOF
dn: ${dc_string:1}
objectClass: dcObject
objectClass: organization
dc: ${dc_parts[0]}
o: ${SLAPD_ORGANIZATION}
description: ${SLAPD_ORGANIZATION}

dn: ${SLAPD_ADMIN_USER}
objectclass: organizationalRole
cn: ${admin_cn}
EOF

    echo ">>> Configuring initial database..."
    slapadd -n 1 -F $CONFIG_DIR -l /tmp/ldif
fi

echo
echo ">>> Starting slapd with config dir $CONFIG_DIR..."
exec $EXE -F $CONFIG_DIR -d $LOG_LEVEL -h "ldap:// ldapi:/// $LDAPS_URI"
