#!/usr/local/bin/bash

set -o pipefail

LOGFILE="/var/log/tredly-install.log"
TREDLYBUILD_GIT_URL="https://github.com/tredly/tredly-build.git"
TREDLYAPI_GIT_URL="https://github.com/tredly/tredly-api.git"
DEFAULT_CONTAINER_SUBNET="10.99.0.0/16"

DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."

source "${DIR}/lib/util.sh"
source "${DIR}/lib/output.sh"
# make sure this script is running as root
cmn_assert_running_as_root

# Ask the user which interface they would like tredly set up on
IFS=$'\n' _interfaces=($( ifconfig | grep "^[a-zA-Z].*[0-9].*:" | grep -v "^lo0:" | grep -v "^bridge[0-9].*:" | awk '{ print $1 }' | tr -d : ))
echo ''
e_header "Installing Tredly-Host"
e_note "Configuring Networking"
echo ''

# if only one interface was found then use that by default
if [[ ${#_interfaces[@]} -eq 1 ]]; then
    EXT_INTERFACE="${_interfaces[0]}"
else
    while [[ -z "${EXT_INTERFACE}" ]]; do
        # have the user select the interface
        echo "More than one interface was found on this machine:"
        for _i in ${!_interfaces[@]}; do
            echo "$(( ${_i} + 1 )). ${_interfaces[${_i}]}"
        done

        read -p "Which would you like to use as your external interface? " _userSelectInterface

        # ensure that the value we received lies within the bounds of the array
        if [[ ${_userSelectInterface} -lt 1 ]] || [[ ${_userSelectInterface} -gt ${#_interfaces[@]} ]] || ! is_int ${_userSelectInterface}; then
            e_error "Invalid selection. Please try again."
            _userSelectInterface=''
        elif [[ -n "$( ifconfig | grep "^${_interfaces[$(( ${_userSelectInterface} - 1 ))]}:" )" ]]; then
            EXT_INTERFACE="${_interfaces[$(( ${_userSelectInterface} - 1 ))]}"
        fi
    done
fi

echo "Using ${EXT_INTERFACE} as your external interface."

# check if this has an ip address assigned to it
DEFAULT_EXT_IP=$( ifconfig ${EXT_INTERFACE} | grep 'inet ' | awk '{ print $2 }' )
DEFAULT_EXT_MASK_HEX=$( ifconfig ${EXT_INTERFACE} | grep 'inet ' | awk '{ print $4 }' | cut -d 'x' -f 2 )

DEFAULT_EXT_MASK=$(( 16#${DEFAULT_EXT_MASK_HEX:0:2} )).$(( 16#${DEFAULT_EXT_MASK_HEX:2:2} )).$(( 16#${DEFAULT_EXT_MASK_HEX:4:2} )).$(( 16#${DEFAULT_EXT_MASK_HEX:6:2} ))
DEFAULT_EXT_GATEWAY=$( netstat -r4n | grep '^default' | awk '{ print $2 }' )

_changeIP="y"

if [[ -z "${DEFAULT_EXT_IP}" ]]; then
    e_note "No ip address is set for this interface."
else
    e_note "This interface currently has an ip address of ${DEFAULT_EXT_IP}."

    # check for a dhcp leases file for this interface
    if [[ -f "/var/db/dhclient.leases.${EXT_INTERFACE}" ]]; then
        # look for its current ip address within the leases file
        _numLeases=$( grep -E "${DEFAULT_EXT_IP}" "/var/db/dhclient.leases.${EXT_INTERFACE}" | wc -l )

        if [[ ${_numLeases} -gt 0 ]]; then
            # found a current lease for this ip address so throw a warning
            echo -e "${_colourMagenta}=============================================================================="
            echo -e "${_formatBold}WARNING!${_formatReset}${_colourMagenta} The current IP address ${DEFAULT_EXT_IP} was set using DHCP!"
            echo "It is recommended that this address be changed to be outside of your DHCP pool"
            echo -e "==============================================================================${_colourDefault}"
        fi
    fi

    echo ''
    read -p "Would you like to change it? (y/n) " _changeIP
fi

if [[ "${_changeIP}" == 'y' ]] || [[ "${_changeIP}" == 'Y' ]]; then
    _user_EXT_IP=''
    while [[ -z "${EXT_IP}" ]]; do

        read -p "Please enter an IP address for ${EXT_INTERFACE} [${DEFAULT_EXT_IP}]: " _user_EXT_IP

        # if no input received then use the default
        if [[ -z ${_user_EXT_IP} ]] && [[ -n ${DEFAULT_EXT_IP} ]]; then
            echo "Using default of ${DEFAULT_EXT_IP}"
            EXT_IP="${DEFAULT_EXT_IP}"
        else
            # validate it
            if is_valid_ip4 "${_user_EXT_IP}"; then
                EXT_IP="${_user_EXT_IP}"
            else
                echo "Invalid IP4 Address."
            fi
        fi
    done

    _user_EXT_MASK=''
    while [[ -z "${EXT_MASK}" ]]; do
        read -p "Please enter a netmask for ${EXT_INTERFACE} [${DEFAULT_EXT_MASK}]: " _user_EXT_MASK

        # if no input received then use the default
        if [[ -z ${_user_EXT_MASK} ]] && [[ -n ${DEFAULT_EXT_MASK} ]]; then
            echo "Using default of ${DEFAULT_EXT_MASK}"
            EXT_MASK="${DEFAULT_EXT_MASK}"
        else
            # validate it
            if is_valid_ip4 "${_user_EXT_MASK}"; then
                EXT_MASK="${_user_EXT_MASK}"
            else
                echo "Invalid subnet mask."
            fi
        fi
    done

    _user_EXT_GATEWAY=''
    while [[ -z "${EXT_GATEWAY}" ]]; do
        read -p "Please enter your default gateway for ${EXT_INTERFACE} [${DEFAULT_EXT_GATEWAY}]: " _user_EXT_GATEWAY

        # if no input received then use the default
        if [[ -z ${_user_EXT_GATEWAY} ]] && [[ -n ${DEFAULT_EXT_GATEWAY} ]]; then
            echo "Using default of ${DEFAULT_EXT_GATEWAY}"
            EXT_GATEWAY="${DEFAULT_EXT_GATEWAY}"
        else
            # validate it
            if is_valid_ip4 "${_user_EXT_GATEWAY}"; then
                EXT_GATEWAY="${_user_EXT_GATEWAY}"
            else
                echo "Invalid IP4 Address"
            fi
        fi
    done
else
    # set the variables to the default values
    EXT_IP="${DEFAULT_EXT_IP}"
    EXT_MASK="${DEFAULT_EXT_MASK}"
    EXT_GATEWAY="${DEFAULT_EXT_GATEWAY}"
fi

_user_MY_HOSTNAME=''
while [[ -z "${MY_HOSTNAME}" ]]; do
    read -p "Please enter a hostname for your host [${HOSTNAME}]: " _user_MY_HOSTNAME

    # if no input received then use the default
    if [[ -z ${_user_MY_HOSTNAME} ]] && [[ -n ${HOSTNAME} ]]; then
        echo "Using default of ${HOSTNAME}"
        MY_HOSTNAME="${HOSTNAME}"
    else
        # validate it
        if [[ -n "${_user_MY_HOSTNAME}" ]]; then
            MY_HOSTNAME="${_user_MY_HOSTNAME}"
        else
            echo "Invalid Hostname"
        fi
    fi
done

_user_CONTAINER_SUBNET=''
while [[ -z "${CONTAINER_SUBNET}" ]]; do
    read -p "Please enter the private subnet for your containers [${DEFAULT_CONTAINER_SUBNET}]: " _user_CONTAINER_SUBNET

    # if no input received then use the default
    if [[ -z ${_user_CONTAINER_SUBNET} ]] && [[ -n ${DEFAULT_CONTAINER_SUBNET} ]]; then
        echo "Using default of ${DEFAULT_CONTAINER_SUBNET}"
        CONTAINER_SUBNET="${DEFAULT_CONTAINER_SUBNET}"
    else
        # validate it

        # split it into network and cidr
        _user_CONTAINER_SUBNET_NET="$( lcut "${_user_CONTAINER_SUBNET}" '/')"
        _user_CONTAINER_SUBNET_CIDR="$( rcut "${_user_CONTAINER_SUBNET}" '/')"

        if ! is_valid_ip4 "${_user_CONTAINER_SUBNET_NET}" || ! is_valid_cidr "${_user_CONTAINER_SUBNET_CIDR}"; then
            echo "Invalid network address ${_user_CONTAINER_SUBNET}. Please use the format x.x.x.x/y, eg 10.0.0.0/16"
        else
            CONTAINER_SUBNET="${_user_CONTAINER_SUBNET}"
        fi
    fi
done

# extract the net and cidr from the container subnet we are using
CONTAINER_SUBNET_NET="$( lcut "${CONTAINER_SUBNET}" '/')"
CONTAINER_SUBNET_CIDR="$( rcut "${CONTAINER_SUBNET}" '/')"
# Get the default host ip address on the private container network
_hostPrivateIP=$( get_last_usable_ip4_in_network "${CONTAINER_SUBNET_NET}" "${CONTAINER_SUBNET_CIDR}" )

echo -e "${_colourMagenta}"
echo -e '===================================================='
echo -e "Configuring Tredly-Host with the following settings:"
echo -e "===================================================="
{
    echo -e "Hostname:^${MY_HOSTNAME}"
    echo -e "External Interface:^${EXT_INTERFACE}"
    echo -e "    IP Address:^${EXT_IP}"
    echo -e "    Subnet:^${EXT_MASK}"
    echo -e "    External Gateway:^${EXT_GATEWAY}"
    echo -e "Container Subnet:^${CONTAINER_SUBNET}"
} | column -ts^
echo '===================================================='
echo -e "${_colourDefault}"
read -p "Are these settings OK? (y/n) " _userContinueToConfigure

# check if user wanted to continue
if [[ "${_userContinueToConfigure}" != 'y' ]] && [[ "${_userContinueToConfigure}" != 'Y' ]]; then
    echo "Exiting tredly-host..."
    exit 1
fi

##########

# Do checks at the start so the user can walk away while installation happens
_vimageInstalled=$( sysctl kern.conftxt | grep '^options[[:space:]]VIMAGE$' | wc -l )
if [[ ${_vimageInstalled} -gt 0 ]]; then
    # check for a kernel source directory
    _downloadSource="y"
    _sourceExists=""
    if [[ -d '/usr/src/sys' ]]; then
        _sourceExists="true"
        echo "It appears that the kernel source files already exist in /usr/src/sys"
        read -p "Do you want to download them again? (y/n) " _downloadSource
    fi
fi

##########

# set up tredly api
e_note "Configuring Tredly-API"
_exitCode=1
cd /tmp
# if the directory for tredly-api already exists, then delete it and start again
if [[ -d "/tmp/tredly-api" ]]; then
    echo "Cleaning previously downloaded Tredly-API"
    rm -rf /tmp/tredly-api
fi

while [[ ${_exitCode} -ne 0 ]]; do
    git clone ${TREDLYAPI_GIT_URL}
    _exitCode=$?
done

cd /tmp/tredly-api
./install.sh
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Update FreeBSD and install updates
e_note "Fetching and Installing FreeBSD Updates"
freebsd-update fetch install | tee -a "${LOGFILE}"
if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# set up pkg
e_note "Configuring PKG"
rm /usr/local/etc/pkg.conf
cp ${DIR}/os/pkg.conf /usr/local/etc/
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Install Packages
e_note "Installing Packages"
_exitCode=0
pkg install -y vim-lite | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y rsync | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y openntpd | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y bash | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y git | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y nginx | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
pkg install -y unbound | tee -a "${LOGFILE}"
_exitCode=$(( ${PIPESTATUS[0]} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure /etc/rc.conf
e_note "Configuring /etc/rc.conf"
_exitCode=0
rm /etc/rc.conf
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/rc.conf /etc/
_exitCode=$(( ${_exitCode} & $? ))
# change the network information in rc.conf
sed -i '' "s|ifconfig_bridge0=.*|ifconfig_bridge0=\"addm ${EXT_INTERFACE} up\"|g" "/etc/rc.conf"
_exitCode=$(( ${_exitCode} & $? ))
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure SSH
_exitCode=0
e_note "Configuring SSHD"
rm /etc/ssh/sshd_config
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/sshd_config /etc/ssh/sshd_config
_exitCode=$(( ${_exitCode} & $? ))
# change the networking data for ssh
sed -i '' "s|ListenAddress .*|ListenAddress ${EXT_IP}|g" "/etc/ssh/sshd_config"
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure Vim
e_note "Configuring VIM"
cp ${DIR}/os/vimrc /usr/local/share/vim/vimrc
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure IPFW
e_note "Configuring IPFW"
_exitCode=0
mkdir -p /usr/local/etc
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/ipfw.rules /usr/local/etc/ipfw.rules
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/ipfw.layer4 /usr/local/etc/ipfw.layer4
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/ipfw.vars /usr/local/etc/ipfw.vars
_exitCode=$(( ${_exitCode} & $? ))

# Removed ipfw start for now due to its ability to disconnect a user from their host
#service ipfw start
#_exitCode=$(( ${_exitCode} & $? ))
if [[ $_exitCode -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure OpenNTP
_exitCode=0
e_note "Configuring OpenNTP"
rm /usr/local/etc/ntpd.conf
cp ${DIR}/os/ntpd.conf /usr/local/etc/
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure zfs scrubbing
#vim /etc/periodic.conf

##########

# Change kernel options
e_note "Configuring kernel options"
_exitCode=0
rm /boot/loader.conf
cp ${DIR}/os/loader.conf /boot/
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

e_note "Configuring Sysctl"
rm /etc/sysctl.conf
cp ${DIR}/os/sysctl.conf /etc/
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure fstab to fix bash bug
if [[ $( grep "/dev/fd" /etc/fstab | wc -l ) -eq 0 ]]; then
    e_note "Configuring Bash"
    echo "fdesc                   /dev/fd fdescfs rw              0       0" >> /etc/fstab
    if [[ $? -eq 0 ]]; then
        e_success "Success"
    else
        e_error "Failed"
    fi
else
   e_note "Bash already configured"
fi

##########

# Configure HTTP Proxy
e_note "Configuring Layer 7 (HTTP) Proxy"
_exitCode=0
mkdir -p /usr/local/etc/nginx/access
_exitCode=$(( ${_exitCode} & $? ))
mkdir -p /usr/local/etc/nginx/server_name
_exitCode=$(( ${_exitCode} & $? ))
mkdir -p /usr/local/etc/nginx/proxy_pass
_exitCode=$(( ${_exitCode} & $? ))
mkdir -p /usr/local/etc/nginx/ssl
_exitCode=$(( ${_exitCode} & $? ))
mkdir -p /usr/local/etc/nginx/upstream
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/proxy/nginx.conf /usr/local/etc/nginx/
_exitCode=$(( ${_exitCode} & $? ))
cp -R ${DIR}/proxy/proxy_pass /usr/local/etc/nginx/
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Configure Unbound DNS
e_note "Configuring Unbound"
_exitCode=0
mkdir -p /usr/local/etc/unbound/configs
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/dns/unbound.conf /usr/local/etc/unbound/
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

##########

# Get tredly-build and install it
e_note "Configuring Tredly-build"
_exitCode=1
cd /tmp
# if the directory for tredly-build already exists, then delete it and start again
if [[ -d "/tmp/tredly-build" ]]; then
    echo "Cleaning previously downloaded Tredly-build"
    rm -rf /tmp/tredly-build
fi

while [[ ${_exitCode} -ne 0 ]]; do
    git clone ${TREDLYBUILD_GIT_URL}
    _exitCode=$?
done

cd /tmp/tredly-build
./tredly.sh install clean
_exitCode=$?
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

# initialise tredly
tredly init

##########

# Setup crontab
e_note "Configuring Crontab"
_exitCode=0
mkdir -p /usr/local/host/
_exitCode=$(( ${_exitCode} & $? ))
cp ${DIR}/os/crontab /usr/local/host/
_exitCode=$(( ${_exitCode} & $? ))
crontab /usr/local/host/crontab
_exitCode=$(( ${_exitCode} & $? ))
if [[ ${_exitCode} -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi


if [[ ${_vimageInstalled} -ne 0 ]]; then
    echo "Skipping kernel recompile as this kernel appears to already have VIMAGE compiled."
else
    echo "Recompiling kernel as this kernel does not have VIMAGE built in"
    echo "Please note this will take some time."

    # lets compile the kernel for VIMAGE!

    # download the source if the user said yes
    if [[ "${_downloadSource}" == 'y' ]] || [[ "${_downloadSource}" == 'Y' ]]; then
        _thisRelease=$( sysctl -n kern.osrelease | cut -d '-' -f 1 -f 2)
        # download the src file
        fetch http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${_thisRelease}/src.txz -o /tmp

        # move the old source to another dir if it already exists
        if [[ "${_sourceExists}" == "true" ]]; then
            # clean up the old source
            mv /usr/src/sys /usr/src/sys.old
        fi

        # unpack new source
        tar -C / -xzf /tmp/src.txz
    fi

    # copy in the tredly kernel configuration file
    cp ${DIR}/kernel/TREDLY /usr/src/sys/amd64/conf

    cd /usr/src

    # work out how many cpus are available to this machine, and use 80% of them to speed up compile
    _availCpus=$( sysctl -n hw.ncpu )
    _useCpus=$( echo "scale=2; ${_availCpus}*0.8" | bc | cut -d'.' -f 1 )

    # if we have a value less than 1 then set it to 1
    if [[ ${_useCpus} -lt 1 ]]; then
        _useCpus=1
    fi

    e_note "Compiling kernel using ${_useCpus} CPUs..."
    make -j${_useCpus} buildkernel KERNCONF=TREDLY

    # only install the kernel if the build succeeded
    if [[ $? -eq 0 ]]; then
        make installkernel KERNCONF=TREDLY
    fi

fi



##########
# Enable the cloned interfaces
e_note "Enabling Cloned Interface(s)"
service netif cloneup
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

# now that everything is installed, set up the networking
# Configure IP on Host to communicate with Containers
e_note "Configuring bridge1 interface"
ifconfig bridge1 inet ${_hostPrivateIP} netmask $( cidr2netmask "${CONTAINER_SUBNET_CIDR}" )
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

# use tredly to set network details
e_note "Setting Host Network"
tredly config host network "${EXT_INTERFACE}" "${EXT_IP}/$( netmask2cidr "${EXT_MASK}" )" "${EXT_GATEWAY}" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

e_note "Setting Host Hostname"
tredly config host hostname "${MY_HOSTNAME}" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

e_note "Setting Container Subnet"
tredly config container subnet "${CONTAINER_SUBNET}" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    e_success "Success"
else
    e_error "Failed"
fi

#####
# TODO: start services? This fails at the moment due to bridge1 not existing
