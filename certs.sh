#!/usr/bin/env bash
# shellcheck disable=SC2001
# 
# Copyright (c) 2018-2022 DSI Université Rennes 2 - Yann 'Ze' Richard <yann.richard@univ-rennes2.fr>
#
# SPDX-License-Identifier: GPL-3.0-or-later
# License-Filename: LICENSE 
LDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
echoerr() { echo "$@" 1>&2; }

# doit pointer vers le répertoire certs
WORKDIR="$LDIR"
mkdir -p "$WORKDIR/archive"
mkdir -p "$WORKDIR/live"

TMPDIR=$(mktemp -d -t 'certificate-tools.XXXXXX')
if [[ ! "$TMPDIR" || ! -d "$TMPDIR" ]]; then
    echoerr "Could not create temp dir"
    exit 1
fi
trap 'rm -rf "$TMPDIR"' EXIT

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="INFO"

CERT_CONFIG_FILE=''
# Default user/group for certs/key
CERT_USER='root'
CERT_GROUP='ssl-cert'
# Loading local configuration to override defaults
if [ -e "/etc/default/certificate-tools" ]
then
    # shellcheck disable=SC1091
    source "/etc/default/certificate-tools"
fi

if ! getent group root "${CERT_GROUP}" > /dev/null
then
    # group does not exists
    CERT_GROUP='root'
fi

# logThis "This will not log" "ERROR"
# logThis "This will log" "WARN"
# logThis "This will log" "INFO"
# logThis "This will not log" "DEBUG"

logThis() {
    local log_message="$1"
    local log_priority="$2"

    # check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    # check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    # log here
    echoerr "${log_priority} : ${log_message}" 
}

function getCertificateAlternativeName () {
    local CERTFILE=$1
    DNSLIST=$(openssl x509 -noout -text -in "$CERTFILE" | awk '/X509v3 Subject Alternative Name/ {getline;gsub(/ /, "", $0); print}' | tr -d "DNS:" | sed 's/,/ /g')
    echo "$DNSLIST"
}

function isValidCaCertificate() {
    local CERTFILE=$1
    local res
    if [ -e "$CERTFILE" ]
    then
        openssl verify -verbose "$CERTFILE" > /dev/null
        res=$?
        # 0 = success
        return $res
    fi
    return 1
}

function getChainFromCert() {
    local CERTFILE="$1"
    local LASTCHAINFILE="$CERTFILE"
    local FINALFILE
    local CHAINURI
    local CHAINSUBJECT
    local ISSUERSUBJECT
    local CHAINFILE
    FINALFILE=$(mktemp --tmpdir="$TMPDIR" "final-XXX")

    while true
    do
        CHAINURI=$(openssl x509 -noout -text -in "$LASTCHAINFILE" | grep 'CA Issuers' | sed 's/.*URI://')
        if [ -z "$CHAINURI" ]
        then
            logThis "Last Certificate has no URI included, probably a root CA, we stop here" "DEBUG"
            break
        fi
        CHAINFILE=$(mktemp --tmpdir="$TMPDIR" "next-XXX")
        logThis "getting $CHAINURI into $CHAINFILE" "DEBUG"
        wget -q -O "$CHAINFILE" "$CHAINURI"
        if [ ! -s "$CHAINFILE" ]
        then 
            logThis "Last Certificate has no URI included, probably a root CA, we stop here" "ERROR"
            LAST_RETURN="ERROR"
            break
        fi
        if ! grep -q "BEGIN CERTIFICATE" "$CHAINFILE"
        then
            # DER format => convert to PEM
            logThis "Convert $CHAINFILE from DER to PEM format" "DEBUG"
            openssl x509 -inform der -in "$CHAINFILE" -out "$CHAINFILE.pem"
            rm "$CHAINFILE"
            mv "$CHAINFILE.pem" "$CHAINFILE"
        fi
        CHAINSUBJECT=$(openssl x509 -noout -subject -in "$CHAINFILE" | sed 's/subject=//')
        ISSUERSUBJECT=$(openssl x509 -noout -issuer -in "$CHAINFILE" | sed 's/issuer=//')
        logThis "CurrentChain        : $CHAINSUBJECT" "DEBUG"
        logThis "CurrentChain Issuer : $ISSUERSUBJECT)" "DEBUG"
        if [ "$CHAINSUBJECT" != "$ISSUERSUBJECT" ]
        then
            # Add CA CERT to bundle.
            logThis "Add current into final result : $CHAINSUBJECT" "DEBUG"
            {
                echo ""
                echo "# $CHAINSUBJECT"
                cat "$CHAINFILE"
            } >> "$FINALFILE"
        else
            break
        fi
        LASTCHAINFILE="$CHAINFILE"
    done
    LAST_RETURN="$FINALFILE"
}

function getCertificateFromBundle () {
    local CERTFILE="$1"
    local file=''
    local CERTIFICATE='ERROR'
    local CHAIN=''

    local certHash
    local subject
    local tmpfile

    # shellcheck disable=SC1083
    csplit -s -z -k -f "$TMPDIR/getItFromFilecert" "$CERTFILE" '/-----BEGIN CERTIFICATE-----/' {*}
    for file in "$TMPDIR"/getItFromFilecert*
    do
        certHash=$(openssl x509 -hash -noout -in "$file")
        subject=$(openssl x509 -noout -subject -in "$file")
        if [ -e "/etc/ssl/certs/${certHash}.0" ]
        then
            CHAIN="$CHAIN $file"
        else
            HASCAFALSE=$(openssl x509 -noout -text -in "$file" | grep -A2 "X509v3 Basic Constraints:" | grep -E "CA:FALSE|CA:TRUE")
            if [[ $HASCAFALSE =~ "CA:FALSE" ]] || [[ -z "$HASCAFALSE" ]]
            then
                logThis "Certificat trouvé dans $(basename "$CERTFILE") : $subject" "DEBUG"
                CERTIFICATE=$(cat "$file")
            elif [[ $HASCAFALSE =~ "CA:TRUE" ]]
            then
                logThis "CA Cert (untrusted) : $subject" "DEBUG"
                CHAIN="$CHAIN $file"
            else
                logThis "Error for $subject" "DEBUG"
            fi
        fi
    done

    if [ "$CERTIFICATE" != "ERROR" ]
    then
        tmpfile=$(mktemp --tmpdir="$TMPDIR" "gicert-XXX")
        echo "$CERTIFICATE" > "$tmpfile"
        LAST_RETURN="$tmpfile"
    else
        logThis "Unknown Option #2 $2 for getCertificateFromBundle()" "ERROR"
        logThis "Unknown Option #2 $2 for getCertificateFromBundle()" "ERROR"
        LAST_RETURN="ERROR"
    fi
    rm "$TMPDIR"/getItFromFilecert*
}

function getExpireDays () {
    local filename="$1"

    local now_epoch
    local expiry_date
    local expiry_epoch
    local expiry_days

    now_epoch=$( date +%s )
    expiry_date=$( openssl x509 -inform pem -noout -enddate -in "$filename" | cut -d "=" -f 2 )
    expiry_epoch=$( date -d "$expiry_date" +%s )
    # shellcheck disable=SC2004
    expiry_days=$(( ($expiry_epoch - $now_epoch) / (3600 * 24) ))
    echo "$expiry_days"
}

function isNotExpiredCertificate () {
    local filename="$1"

    local now_epoch
    local expiry_date
    local expiry_epoch
    local expiry_days

    now_epoch=$( date +%s )
    expiry_date=$( openssl x509 -inform pem -noout -enddate -in "$filename" | cut -d "=" -f 2 )
    expiry_epoch=$( date -d "$expiry_date" +%s )
    # shellcheck disable=SC2004
    expiry_days=$(( ($expiry_epoch - $now_epoch) / (3600 * 24) ))
    if [ $expiry_days -gt 0 ] 
    then
        logThis "  $filename : NOT expired $expiry_epoch - $now_epoch ($expiry_days > 0)" "DEBUG"
        # 0 for success
        return 0
    else
        logThis "  $filename : expired ($expiry_days <= 0)" "DEBUG"
        return 255
    fi  
}

function isCertificatePrivateMatch () {
    local CERTFILE="$1"
    local KEYFILE="$2"

    local CERTSUM
    local KEYSUM
    if [ ! -e "$CERTFILE" ]
    then
        logThis "ERR : $CERTFILE (cert) doest not exists" "DEBUG"
        return 255
    fi
    if [ ! -e "$KEYFILE" ]
    then
        logThis "ERR : $KEYFILE (key) doest not exists" "DEBUG"
        return 255
    fi

    CERTSUM=$(openssl x509 -in "$CERTFILE" -pubkey -noout -outform pem | sha256sum)
    KEYSUM=$(openssl pkey -in "$KEYFILE" -pubout -outform pem | sha256sum)

    if [ "$CERTSUM" = "$KEYSUM" ]
    then
        # 0 for success
        return 0
    else
        return 255
    fi
}

function getFQDNFromCert () {
    local CERTFILE="$1"
    local CN
    CN=$(openssl x509 -noout -subject -nameopt multiline -in "$CERTFILE" | grep commonName | sed 's/ *commonName *= //')
    echo "$CN"
}

function getBeginYearFromCert () {
    local CERTFILE="$1"
    local start_date
    local year

    start_date=$( openssl x509 -inform pem -noout -startdate -in "$CERTFILE" | cut -d "=" -f 2 )
    year=$(date -d "$start_date" +%Y)
    echo "$year"
}

function getSerialFromCert () {
    local CERTFILE="$1"
    local serial

    serial=$( openssl x509 -inform pem -noout -serial -in "$CERTFILE" | cut -d "=" -f 2 )
    echo "$serial"
}

function buildPFX() {
    # complete path to the certificate file in archive/
    PRIMARY_CERT="$1"
    FQDN="$2"

    BASENAME=$(basename "$PRIMARY_CERT")
    DESTCERTDIR="$WORKDIR/archive/$FQDN"
    DESTBASENAME=$(echo "$BASENAME" | sed 's/.pem$//')

    if [ -e "${DESTCERTDIR}/${DESTBASENAME}.pfx" ]
    then
        rm "${DESTCERTDIR}/${DESTBASENAME}.pfx"
    fi

    # Build PFX file
    openssl pkcs12 -export -out "${DESTCERTDIR}/${DESTBASENAME}.pfx" \
                -inkey "$DESTCERTDIR/$DESTBASENAME.key" \
                -in "$DESTCERTDIR/$DESTBASENAME.pem" \
                -passout "pass:${CERT_PFX_PASSWORD}" \
                -certfile "$DESTCERTDIR/$DESTBASENAME-fullchain.pem"
}

function install(){
    local FROMDIR
    local HELPFILE
    local BASENAME
    local WITHOUTEXT
    local FQDN
    local YEAR
    local SERIAL
    local KEY
    local DESTCERTDIR
    local DESTBASENAME
    local OLDBASENAME
    local OLDBASENAMESERIAL
    local theCertOnlyFile

    FROMDIR=$(realpath "$1")
    HELPFILE=$(mktemp --tmpdir="$TMPDIR" "helpfile-XXX")
    for oricert in "$FROMDIR"/*.pem
    do
        logThis "Try $oricert" "DEBUG"

        getCertificateFromBundle "$oricert"
        theCertOnlyFile="$LAST_RETURN"
        LAST_RETURN=''
        if isNotExpiredCertificate "$theCertOnlyFile"
        then
            BASENAME=$(basename "$oricert")
            WITHOUTEXT=${BASENAME%.pem}
            FQDN=$(getFQDNFromCert "$theCertOnlyFile")
            YEAR=$(getBeginYearFromCert "$theCertOnlyFile")
            SERIAL=$(getSerialFromCert "$theCertOnlyFile")
            KEY=$(find "$FROMDIR" -maxdepth 2 -iname "$WITHOUTEXT.key" 2> /dev/null | head -1)
            DESTCERTDIR="$WORKDIR/archive/$FQDN"
            DESTBASENAME="$YEAR-$SERIAL-$FQDN"
            OLDBASENAME="$YEAR-$FQDN"
            if [ -e "$DESTCERTDIR/$OLDBASENAME.pem" ] 
            then
                logThis "detecting same old base name : $DESTCERTDIR/$OLDBASENAME.pem ; checking if it's the same" "DEBUG"
                # Perhaps just already here, or new cert 
                OLDBASENAMESERIAL=$(getSerialFromCert "$DESTCERTDIR/$OLDBASENAME.pem")
                if [ "$SERIAL" == "$OLDBASENAMESERIAL" ]
                then
                    logThis "$oricert is already installed as $DESTCERTDIR/$OLDBASENAME.pem ; skipping !" "DEBUG"
                    continue
                fi
            fi

            if [ -e "$KEY" ]
            then
                if isCertificatePrivateMatch "$theCertOnlyFile" "$KEY"
                then
                    logThis "Found : $BASENAME / $WITHOUTEXT.key" "INFO"
                    getChainFromCert "$theCertOnlyFile"
                    CHAINFILE="$LAST_RETURN"
                    if isValidCaCertificate "$CHAINFILE"
                    then 
                        LAST_RETURN=''
                        mkdir -p "$DESTCERTDIR"

                        # Fullchain cert (cert must be in first place in file)
                        cp "$theCertOnlyFile" "$DESTCERTDIR/$DESTBASENAME-fullchain.pem"
                        cat "$CHAINFILE" >> "$DESTCERTDIR/$DESTBASENAME-fullchain.pem"
                        # chain alone 
                        cp "$CHAINFILE" "$DESTCERTDIR/$DESTBASENAME-chain.pem"
                        # cert alone
                        cp "$theCertOnlyFile" "$DESTCERTDIR/$DESTBASENAME.pem"
                        # copy key
                        cp -a "$KEY" "$DESTCERTDIR/$DESTBASENAME.key"
                        # Create bundle with key for HAProxy
                        cat "$DESTCERTDIR/$DESTBASENAME-fullchain.pem" "$DESTCERTDIR/$DESTBASENAME.key" >  "$DESTCERTDIR/$DESTBASENAME-fullchainkey.key"

                        if [ -n "$CERT_PFX_PASSWORD" ]
                        then
                            buildPFX "$DESTCERTDIR/$DESTBASENAME.pem" "$FQDN"
                        fi

                        logThis "Installed as $DESTCERTDIR/$DESTBASENAME.*" "INFO"
                        # print help for apache configuration
                        {
                            echo ""
                            echo "    # Apache SSL Certs configuration for $FQDN"
                            echo "    SSLCertificateFile      $WORKDIR/live/${FQDN}/fullchain.pem"
                            echo "    SSLCertificateKeyFile   $WORKDIR/live/${FQDN}/privkey.pem"
                        } >> "$HELPFILE"
                    else
                        logThis "ERROR when trying to get CA chain from cert" "ERROR"
                    fi
                else
                    logThis "ERROR not a valid couple of CERT/KEY : $BASENAME / $WITHOUTEXT.key" "ERROR"
                fi
            else
                logThis "No key found for $oricert, ignoring" "DEBUG"
            fi
        else
            logThis "$oricert is expired, ignoring" "WARNING"
        fi
    done
    update
    cat "$HELPFILE"
}

function fixRights(){
    CERTARCHIVEDIR="$1"
    if [[ $EUID -eq 0 ]]
    then
        find "$CERTARCHIVEDIR" -type f -iname "*.pem" -exec chown ${CERT_USER}:${CERT_GROUP} {} \;
        find "$CERTARCHIVEDIR" -type f -iname "*.key" -exec chown ${CERT_USER}:${CERT_GROUP} {} \;
    fi
    find "$CERTARCHIVEDIR" -type f -iname "*.pfx" -exec chmod 0644 {} \;
    find "$CERTARCHIVEDIR" -type f -iname "*.pem" -exec chmod 0644 {} \;
    find "$CERTARCHIVEDIR" -type f -iname "*.key" -exec chmod 0640 {} \;
}

function update(){
    local nagiosCheck="0"
    if [ "$1" == "-c" ]
    then 
        local fqdnListOK=''
        local fqdnListWarning=''
        local fqdnListCritical=''
        local warningDays
        local criticalDays
        warningDays=$(echo "$2" | cut -f1 -d ':')
        criticalDays=$(echo "$2" | cut -f2 -d ':')
        nagiosCheck="1"
    else
        fixRights "$WORKDIR/archive"
    fi
    # shellcheck disable=SC2045
    for fqdn in $(ls "$WORKDIR"/archive/)
    do
        local lastpem=''
        local lasttime=0

        # shellcheck disable=SC2044
        for file in $(find "$WORKDIR/archive/$fqdn/" -iname "*.pem" -type f ! -iname '*-chain.pem' ! -iname '*-fullchain.pem')
        do
            local startdate
            local curtime
            startdate=$(openssl x509 -startdate -noout -in "$file" | cut -d= -f 2)
            curtime=$(date +%s --date="$startdate")
            if [ "$curtime" -gt "$lasttime" ]
            then
                lastpem="$file"
                lasttime=$curtime
            fi
        done

        if [ -n "$lastpem" ]
        then
            local RELATIVELASTPEM
            local fullchainfile
            local chainfile
            local keyfile
            local expireIntoDays
            expireIntoDays=$(getExpireDays "$lastpem")
            if [ "$nagiosCheck" -eq "1" ]
            then
                if (( expireIntoDays > warningDays ))
                then
                    # echo "$fqdn $expireIntoDays"
                    fqdnListOK="$fqdn ($expireIntoDays) $fqdnListOK"
                elif (( expireIntoDays < criticalDays ))
                then
                    # echo "$fqdn ($expireIntoDays) $expireIntoDays"
                    fqdnListCritical="$fqdn ($expireIntoDays) $fqdnListCritical"
                elif (( expireIntoDays < warningDays ))
                then
                    # echo "$fqdn ($expireIntoDays) $expireIntoDays"
                    fqdnListWarning="$fqdn ($expireIntoDays) $fqdnListWarning"
                else
                    echo "WTF with $fqdn ($expireIntoDays)"
                fi
            else
                RELATIVELASTPEM=$(echo "$lastpem" | sed "s#$WORKDIR#../..#")
                # Install latest certs into live path
                if [ ! -d "$WORKDIR/live/$fqdn" ]
                then
                    mkdir -p "$WORKDIR/live/$fqdn"
                fi
                rm -f "$WORKDIR/live/$fqdn"/*.pem 
                rm -f "$WORKDIR/live/$fqdn"/*.pfx
                if [ -n "$BUILD_PFX" ]
                then
                    buildPFX "$lastpem" "$fqdn"
                fi
                ln -s "$RELATIVELASTPEM" "$WORKDIR/live/$fqdn/cert.pem"
                pfxfile=$(echo "$lastpem" | sed 's/.pem$/.pfx/')
                if [ -e "$pfxfile" ]
                then
                    pfxrelativefile=$(echo "$RELATIVELASTPEM" | sed 's/.pem$/.pfx/')
                    ln -s "$pfxrelativefile" "$WORKDIR/live/$fqdn/cert.pfx"
                fi
                fullchainfile=$(echo "$RELATIVELASTPEM" | sed 's/.pem$/-fullchain.pem/')
                ln -s "$fullchainfile" "$WORKDIR/live/$fqdn/fullchain.pem"

                chainfile=$(echo "$RELATIVELASTPEM" | sed 's/.pem$/-chain.pem/')
                ln -s "$chainfile" "$WORKDIR/live/$fqdn/chain.pem"
                
                keyfile=$(echo "$RELATIVELASTPEM" | sed 's/pem$/key/')
                ln -s "$keyfile" "$WORKDIR/live/$fqdn/privkey.pem"

                bundlekey=$(echo "$lastpem" | sed 's/.pem$/-fullchainkey.key/')
                if [ ! -e "$bundlekey" ]
                then
                    # not already created (installed from old version) => go create !
                    realfullchainfile=$(echo "$lastpem" | sed 's/.pem$/-fullchain.pem/')
                    realkeyfile=$(echo "$lastpem" | sed 's/pem$/key/')
                    cat  "$realfullchainfile" "$realkeyfile" > "$bundlekey"
                fi
                relativebundlekey=$(echo "$RELATIVELASTPEM" | sed 's/.pem$/-fullchainkey.key/')
                ln -s "$relativebundlekey"  "$WORKDIR/live/$fqdn/fullchainkey.pem"

                logThis "Rebuild live dir with latest certificate for $fqdn" "INFO"

                # Create live dir for each Subject Alternative Name of the certificate
                for altfqdn in $(getCertificateAlternativeName "$lastpem")
                do
                    if [ "$altfqdn" != "$fqdn" ]
                    then
                        mkdir -p "$WORKDIR/live/$altfqdn"
                        rm -f "$WORKDIR/live/$altfqdn"/*.pem
                        rm -f "$WORKDIR/live/$altfqdn"/*.pfx
                        ln -s "$RELATIVELASTPEM" "$WORKDIR/live/$altfqdn/cert.pem"
                        ln -s "$fullchainfile" "$WORKDIR/live/$altfqdn/fullchain.pem"
                        ln -s "$chainfile" "$WORKDIR/live/$altfqdn/chain.pem"
                        ln -s "$keyfile" "$WORKDIR/live/$altfqdn/privkey.pem"
                        ln -s "$relativebundlekey" "$WORKDIR/live/$altfqdn/fullchainkey.pem"
                        if [ -e "$pfxfile" ]
                        then
                            ln -s "$pfxrelativefile" "$WORKDIR/live/$altfqdn/cert.pfx"
                        fi
                    fi
                done
            fi
        else
            logThis "No certificate found for $fqdn." "WARN"
        fi
    done
    if [ "$nagiosCheck" -eq "1" ]
    then
        local exitStatus=0
        if [ "x$fqdnListCritical" != "x" ]
        then
            echo -n "Critical for Certificate : $fqdnListCritical // "
            exitStatus=2
        fi
        if [ "x$fqdnListWarning" != "x" ]
        then
            echo -n "Warning for Certificate : $fqdnListWarning // "
            if [ $exitStatus -eq "0" ]
            then 
                exitStatus=1
            fi
        fi
        echo "OK : $fqdnListOK"
        exit $exitStatus
    fi
}

function usage () {
    echo "Usage : $0 [-f|--config <configfile>] [-x|--pfx] [-i|--install <path to certs>] [-u|--update] [-c|--check WARNING:CRITICAL] [-h|--help]"
    echo ""
    echo "  -f  --config    specify a config file (default /etc/default/certificate-tools)"
    echo "  -i, --install   Install into certs archive dir with all certs from PATH/*.pem"
    echo "                  private keys are searched in "
    echo "                  PATH/<samename>.key and PATH/private/<samename>.key"
    echo "  -u, --update    Update live dir with certs stored in $LDIR/archive"
    echo "  -x  --pfx       Create PFX/PKCS#12 files if not exists"
    echo "  -c  --check     Nagios compatible check for certificate expiration"
    echo "                  WARNING:CRITICAL are in days"
    echo "  -h, --help      display this help"
    echo ""
}

if [[ $# -eq 0 ]]
then
    usage
    exit 1
fi

# https://www.bahmanm.com/2015/01/command-line-options-parse-with-getopt.html
TEMP=$(getopt -o xf:hi:uc: --long pfx,help,install:,update,check,config: -n 'test.sh' -- "$@")
eval set -- "$TEMP"
while true ; do
    case "$1" in
        -f|--config)
            CERT_CONFIG_FILE="$2"
            if [ -e "$CERT_CONFIG_FILE" ]
            then
                # shellcheck disable=SC1090
                source "$CERT_CONFIG_FILE"
            else
                echoerr "$CERT_CONFIG_FILE does not exists"
                exit 2
            fi
            shift 2;;
        -i|--install)
            install "$2"
            shift 2;;
        -u|--update) 
            update
            shift ;;
        -x|--pfx) 
            BUILD_PFX="1"
            update
            shift ;;
        -c|--check)
            update "-c" "$2"
            shift 2;;
        -h|--help)
            usage
            shift ;;
        --) shift ; break ;;
        *) usage; exit 1 ;;
    esac
done
exit 0
