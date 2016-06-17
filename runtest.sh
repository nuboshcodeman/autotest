#!/bin/bash

#set -e
#set -x

MOCK=/usr/bin/mock
CONFDIR=/etc/mock
ROOTDIR=/var/lib/mock
LIBRARY_PATH=/opt/nubosh/vmsec-host/net/eng
BINARY_PATH=/opt/nubosh/vmsec-host/net/eng/walnut
BIN_CONF_PATH=/opt/nubosh/vmsec-host/net/conf

config=
userid=
vmsec_files=/root/vmsec-files
result_files=/root/result

skip_chroot_setup="no"

[ -f mock.log ] && rm -f mock.log

usage() {
    echo "Usage: $0 [-s] [-c config] [-f vmsec-files] [-r result-files]" >&2
    echo "" >&2
    echo "        -s, skip chroot jail setup if we already have one, default donot skip" >&2
    echo "        -c config, config file path" >&2
    echo "        -f vmsec-files, vmsec-files folder path, default /root/vmsec-files" >&2
    echo "        -r result-files, folder which stores log file and keeps record of failure tests, default /root/result" >&2
    echo "" >&2
    echo "e.g. $0 -c chunjie-test.cfg -f /root/vmsec-files" >&2
    echo "" >&2
}

dependency_check() {
    if [ ! -x $MOCK ]; then
        echo "*** Error: $MOCK does not exists." >&2
        exit 1
    fi

    if [ ! -d $CONFDIR ]; then
        echo "*** Error: $CONFDIR does not exists." >&2
        exit 1
    fi
}

fetch_userid() {
    config=$1
    userid=`grep "config_opts\['root" $config  | cut -d' ' -f3 | tr -d "'"`;
    return 0
}

user_exists_or_create() {
    user=$1
    cat /etc/passwd | grep $user
    if [ $? -eq 1 ]; then
        useradd $user
        usermod -a -G mock $user
    fi

    chgrp mock $config
    [ ! -f $CONFDIR/`basename $config` ] && cp $config $CONFDIR/.
}

prepare_chroot_jail() {
    user=$1

    rootdir=$ROOTDIR/$user
    [ -d $rootdir ] &&  rm -rf $rootdir

    mock_conf=$CONFDIR/`basename $config`
    sudo -u $user $MOCK -r $mock_conf --init
}

deploy_vmsec_files() {
    user=$1
    vmsec_files_folder=$2

    mkdir -p $ROOTDIR/$1/root/local
    mount -o bind $vmsec_files_folder $ROOTDIR/$user/root/local

    cd $vmsec_files_folder
    sed -e 's,@ENABLED@,yes,g' walnuts.conf.in > walnuts.conf
    cd -

    mock_conf=$CONFDIR/`basename $config`
    $MOCK -r $mock_conf  --chroot  "rpm -ivh /local/vmsec-host-common-*.rpm" >> mock.log 2>&1
    $MOCK -r $mock_conf  --chroot  "rpm -ivh /local/vmsec-host-net-*.rpm" >> mock.log 2>&1

    $MOCK -r $mock_conf --chroot  "cp -f /local/license.dat /opt/nubosh/vmsec-host/net/conf/."  >> mock.log 2>&1
    $MOCK -r $mock_conf --chroot  "cp -f /local/walnuts.conf /opt/nubosh/vmsec-host/net/conf/." >> mock.log 2>&1
}

run_offline_packet_test() {
    vmsec_files_folder=$1

    [ -d $result_files ] && rm -rf $result_files
    mkdir -p $result_files

    mock_conf=$CONFDIR/`basename $config`

    echo "*** INFO: Test begin" >&2
    count=0
    if [ -d $vmsec_files_folder/packets ]; then
        for pcap_file in `ls $vmsec_files_folder/packets`; do
            count=$[$count + 1]
            echo "*** INFO: run $count test"

            $MOCK -r $mock_conf --chroot  "LD_LIBRARY_PATH=$LIBRARY_PATH $BINARY_PATH -c $BIN_CONF_PATH/walnuts.conf -r /local/packets/$pcap_file" >> mock.log 2>&1
            $MOCK -r $mock_conf --copyout  /opt/nubosh/vmsec-host/net/log/fast.log  $result_files/$pcap_file.test.fast.log >> mock.log 2>&1
        done
    else
        echo "*** WARN: no offline packets." >&2
        return
    fi

    failure=0
    failure_record=/tmp/test-`uuidgen`-failures
    touch $failure_record
    #verify test result, simple check
    for test_output in `ls $result_files`; do
        size=`stat -c "%s" $result_files/$test_output`

        if [ $size -eq 0 ]; then
            failure=$[$failure + 1]
            echo $test_output >> $failure_record
        fi
    done
    mv $failure_record $result_files/failures
    echo "*** INFO: Test completes"
    echo "" >&2

    echo "========== SUMMARY ==========" >&2
    echo "Total packet test: $count" >&2
    echo "Failure packet test: $failure" >&2
    echo "Save failure test to $result_files/failures" >&2
    echo "" >&2
}

clean_test_stales() {
    user=$1

    mock_conf=$CONFDIR/`basename $config`
    $MOCK -r $mock_conf --chroot "rpm -e vmsec-host-net" >> mock.log 2>&1
    $MOCK -r $mock_conf --chroot "rpm -e vmsec-host-common" >> mock.log 2>&1
    $MOCK -r $mock_conf --chroot "rm -rf /opt/nubosh" >> mock.log 2>&1

    umount $ROOTDIR/$user/root/local

    [ -d $ROOTDIR/$user/root/var/cache/yum ] && umount $ROOTDIR/$user/root/var/cache/yum

    [ -f $CONFDIR/`basename $config` ] && rm -f $CONFDIR/`basename $config`

    cat /etc/passwd | grep $user
    if [ $? -eq 0 ]; then
        userdel $user
        [ -d /home/$user ] && rm -rf /home/$user
    fi

    echo "" >&2
    echo "*** WARN: We still keep the chroot jail env." >&2
    echo "*** WARN: Please manually remove $ROOTDIR/$user if you donot want it." >&2
    echo "" >&2
}

while getopts "c:f:r:sh" opt; do
    case $opt in
        c)
            config=$OPTARG;;
        f)
            vmsec_files=$OPTARG;;
        r)
            result_files=$OPTARG;;
        s)
            skip_chroot_setup="yes";;
        h)
            usage
            exit 0
            ;;
        esac
done

if [ -z "$config" ]; then
    echo "*** WARN: cannot see config file." >&2
    exit 0
fi

if [ ! -f $config ]; then
    echo "*** Error: config file '$config' does not exist." >&2
    exit 1
fi

if [ ! -d $vmsec_files ]; then
    echo "*** Error: vmsec files folder '$vmsec_files' does not exist." >&2
    exit 1
fi

dependency_check

fetch_userid $config

user_exists_or_create $userid

if [ $skip_chroot_setup == "no" ]; then
    prepare_chroot_jail $userid
fi

deploy_vmsec_files $userid $vmsec_files

run_offline_packet_test $vmsec_files

clean_test_stales $userid
