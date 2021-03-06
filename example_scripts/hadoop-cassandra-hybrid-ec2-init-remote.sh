#!/bin/bash -x

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

################################################################################
# Script that is run on each EC2 instance on boot. It is passed in the EC2 user
# data, so should not exceed 16K in size after gzip compression.
#
# This script is executed by /etc/init.d/ec2-run-user-data, and output is
# logged to /var/log/messages.
################################################################################

################################################################################
# Initialize variables
################################################################################

# Substitute environment variables passed by the client
export %ENV%

echo "export %ENV%" >> ~root/.bash_profile
echo "export %ENV%" >> ~root/.bashrc

DEFAULT_CASSANDRA_URL="http://mirror.cloudera.com/apache/cassandra/0.6.4/apache-cassandra-0.6.4-bin.tar.gz"
CASSANDRA_HOME_ALIAS=/usr/local/apache-cassandra

HADOOP_VERSION=${HADOOP_VERSION:-0.20.1}
HADOOP_HOME=/usr/local/hadoop-$HADOOP_VERSION
HADOOP_CONF_DIR=$HADOOP_HOME/conf

PIG_VERSION=${PIG_VERSION:-0.7.0}
PIG_HOME=/usr/local/pig-$PIG_VERSION
PIG_CONF_DIR=$PIG_HOME/conf

SELF_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname`
for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  hybrid_nn)
    HYBRID_NN_HOST=$SELF_HOST
    ;;
  hybrid_jt)
    HYBRID_JT_HOST=$SELF_HOST
    ;;
  esac
done

function register_auto_shutdown() {
  if [ ! -z "$AUTO_SHUTDOWN" ]; then
    shutdown -h +$AUTO_SHUTDOWN >/dev/null &
  fi
}

# Install a list of packages on debian or redhat as appropriate
function install_packages() {
  if which dpkg &> /dev/null; then
    apt-get update
    apt-get -y install $@
  elif which rpm &> /dev/null; then
    yum install -y $@
  else
    echo "No package manager found."
  fi
}

# Install any user packages specified in the USER_PACKAGES environment variable
function install_user_packages() {
  if [ ! -z "$USER_PACKAGES" ]; then
    install_packages $USER_PACKAGES
  fi
}

function install_yourkit() {
	mkdir /mnt/yjp
	YOURKIT_URL="http://www.yourkit.com/download/yjp-9.0.7-linux.tar.bz2"
	curl="curl --retry 3 --silent --show-error --fail"
	$curl -O $YOURKIT_URL
	yourkit_tar_file=`basename $YOURKIT_URL`
    tar xjf $yourkit_tar_file -C /mnt/yjp
    rm -f $yourkit_tar_file
    chown -R hadoop /mnt/yjp
	chgrp -R hadoop /mnt/yjp
}

function install_hadoop() {
  useradd hadoop

  hadoop_tar_url=http://s3.amazonaws.com/hadoop-releases/core/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz
  hadoop_tar_file=`basename $hadoop_tar_url`
  hadoop_tar_md5_file=`basename $hadoop_tar_url.md5`

  curl="curl --retry 3 --silent --show-error --fail"
  for i in `seq 1 3`;
  do
    $curl -O $hadoop_tar_url
    $curl -O $hadoop_tar_url.md5
    if md5sum -c $hadoop_tar_md5_file; then
      break;
    else
      rm -f $hadoop_tar_file $hadoop_tar_md5_file
    fi
  done

  if [ ! -e $hadoop_tar_file ]; then
    echo "Failed to download $hadoop_tar_url. Aborting."
    exit 1
  fi

  tar zxf $hadoop_tar_file -C /usr/local
  rm -f $hadoop_tar_file $hadoop_tar_md5_file

  echo "export HADOOP_HOME=$HADOOP_HOME" >> ~root/.bashrc
  echo 'export PATH=$JAVA_HOME/bin:$HADOOP_HOME/bin:$PATH' >> ~root/.bashrc
}

function install_pig()
{
  pig_tar_url=http://mirror.cloudera.com/apache/hadoop/pig/pig-$PIG_VERSION/pig-$PIG_VERSION.tar.gz
  pig_tar_file=`basename $pig_tar_url`

  curl="curl --retry 3 --silent --show-error --fail"
  for i in `seq 1 3`;
  do
    $curl -O $pig_tar_url
  done

  if [ ! -e $pig_tar_file ]; then
    echo "Failed to download $pig_tar_url. Aborting."
    exit 1
  fi

  tar zxf $pig_tar_file -C /usr/local
  rm -f $pig_tar_file
  
  if [ ! -e $HADOOP_CONF_DIR ]; then
    echo "Hadoop must be installed.  Aborting."
    exit 1
  fi
  
  cp $HADOOP_CONF_DIR/*.xml $PIG_CONF_DIR/

  echo "export PIG_HOME=$PIG_HOME" >> ~root/.bashrc
  echo 'export PATH=$JAVA_HOME/bin:$PIG_HOME/bin:$PATH' >> ~root/.bashrc
}

function prep_disk() {
  mount=$1
  device=$2
  automount=${3:-false}

  echo "warning: ERASING CONTENTS OF $device"
  mkfs.xfs -f $device
  if [ ! -e $mount ]; then
    mkdir $mount
  fi
  mount -o defaults,noatime $device $mount
  if $automount ; then
    echo "$device $mount xfs defaults,noatime 0 0" >> /etc/fstab
  fi
}

function wait_for_mount {
  mount=$1
  device=$2

  mkdir $mount

  i=1
  echo "Attempting to mount $device"
  while true ; do
    sleep 10
    echo -n "$i "
    i=$[$i+1]
    mount -o defaults,noatime $device $mount || continue
    echo " Mounted."
    break;
  done
}

function make_hadoop_dirs {
  for mount in "$@"; do
    if [ ! -e $mount/hadoop ]; then
      mkdir -p $mount/hadoop
      chown hadoop:hadoop $mount/hadoop
    fi
  done
}

# Configure Hadoop by setting up disks and site file
function configure_hadoop() {

  install_packages xfsprogs # needed for XFS

  INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`

  if [ -n "$EBS_MAPPINGS" ]; then
    # EBS_MAPPINGS is like "hybrid_nn,/ebs1,/dev/sdj;hybrid_dn,/ebs2,/dev/sdk"
    # EBS_MAPPINGS is like "ROLE,MOUNT_POINT,DEVICE;ROLE,MOUNT_POINT,DEVICE"
    DFS_NAME_DIR=''
    FS_CHECKPOINT_DIR=''
    DFS_DATA_DIR=''
    for mapping in $(echo "$EBS_MAPPINGS" | tr ";" "\n"); do
      role=`echo $mapping | cut -d, -f1`
      mount=`echo $mapping | cut -d, -f2`
      device=`echo $mapping | cut -d, -f3`
      wait_for_mount $mount $device
      DFS_NAME_DIR=${DFS_NAME_DIR},"$mount/hadoop/hdfs/name"
      FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR},"$mount/hadoop/hdfs/secondary"
      DFS_DATA_DIR=${DFS_DATA_DIR},"$mount/hadoop/hdfs/data"
      FIRST_MOUNT=${FIRST_MOUNT-$mount}
      make_hadoop_dirs $mount
    done
    # Remove leading commas
    DFS_NAME_DIR=${DFS_NAME_DIR#?}
    FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR#?}
    DFS_DATA_DIR=${DFS_DATA_DIR#?}

    DFS_REPLICATION=3 # EBS is internally replicated, but we also use HDFS replication for safety
  else
    case $INSTANCE_TYPE in
    m1.xlarge|c1.xlarge)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data,/mnt3/hadoop/hdfs/data,/mnt4/hadoop/hdfs/data
      ;;
    m1.large)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data
      ;;
    *)
      # "m1.small" or "c1.medium"
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data
      ;;
    esac
    FIRST_MOUNT=/mnt
    DFS_REPLICATION=3
  fi

  case $INSTANCE_TYPE in
  m1.xlarge|c1.xlarge)
    prep_disk /mnt2 /dev/sdc true &
    disk2_pid=$!
    prep_disk /mnt3 /dev/sdd true &
    disk3_pid=$!
    prep_disk /mnt4 /dev/sde true &
    disk4_pid=$!
    wait $disk2_pid $disk3_pid $disk4_pid
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local,/mnt3/hadoop/mapred/local,/mnt4/hadoop/mapred/local
    MAX_MAP_TASKS=8
    MAX_REDUCE_TASKS=4
    CHILD_OPTS=-Xmx680m
    CHILD_ULIMIT=1392640
    ;;
  m1.large)
    prep_disk /mnt2 /dev/sdc true
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx1024m
    CHILD_ULIMIT=2097152
    ;;
  c1.medium)
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  *)
    # "m1.small"
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=2
    MAX_REDUCE_TASKS=1
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    ;;
  esac

  make_hadoop_dirs `ls -d /mnt*`

  # Create tmp directory
  mkdir /mnt/tmp
  chmod a+rwxt /mnt/tmp
  
  mkdir /etc/hadoop
  ln -s $HADOOP_CONF_DIR /etc/hadoop/conf

  ##############################################################################
  # Modify this section to customize your Hadoop cluster.
  ##############################################################################
  cat > $HADOOP_CONF_DIR/hadoop-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>dfs.block.size</name>
  <value>134217728</value>
  <final>true</final>
</property>
<property>
  <name>dfs.data.dir</name>
  <value>$DFS_DATA_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.du.reserved</name>
  <value>1073741824</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.handler.count</name>
  <value>3</value>
  <final>true</final>
</property>
<!--property>
  <name>dfs.hosts</name>
  <value>$HADOOP_CONF_DIR/dfs.hosts</value>
  <final>true</final>
</property-->
<!--property>
  <name>dfs.hosts.exclude</name>
  <value>$HADOOP_CONF_DIR/dfs.hosts.exclude</value>
  <final>true</final>
</property-->
<property>
  <name>dfs.name.dir</name>
  <value>$DFS_NAME_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.namenode.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>dfs.permissions</name>
  <value>true</value>
  <final>true</final>
</property>
<property>
  <name>dfs.replication</name>
  <value>$DFS_REPLICATION</value>
</property>
<property>
  <name>fs.checkpoint.dir</name>
  <value>$FS_CHECKPOINT_DIR</value>
  <final>true</final>
</property>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$HYBRID_NN_HOST:8020/</value>
</property>
<property>
  <name>fs.trash.interval</name>
  <value>1440</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.tmp.dir</name>
  <value>/mnt/tmp/hadoop-\${user.name}</value>
  <final>true</final>
</property>
<property>
  <name>io.file.buffer.size</name>
  <value>65536</value>
</property>
<property>
  <name>mapred.child.java.opts</name>
  <value>$CHILD_OPTS</value>
</property>
<property>
  <name>mapred.child.ulimit</name>
  <value>$CHILD_ULIMIT</value>
  <final>true</final>
</property>
<property>
  <name>mapred.job.tracker</name>
  <value>$HYBRID_JT_HOST:8021</value>
</property>
<property>
  <name>mapred.job.tracker.handler.count</name>
  <value>5</value>
  <final>true</final>
</property>
<property>
  <name>mapred.local.dir</name>
  <value>$MAPRED_LOCAL_DIR</value>
  <final>true</final>
</property>
<property>
  <name>mapred.map.tasks.speculative.execution</name>
  <value>true</value>
</property>
<property>
  <name>mapred.reduce.parallel.copies</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks.speculative.execution</name>
  <value>false</value>
</property>
<property>
  <name>mapred.submit.replication</name>
  <value>10</value>
</property>
<property>
  <name>mapred.system.dir</name>
  <value>/hadoop/system/mapred</value>
</property>
<property>
  <name>mapred.tasktracker.map.tasks.maximum</name>
  <value>$MAX_MAP_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>mapred.tasktracker.reduce.tasks.maximum</name>
  <value>$MAX_REDUCE_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>tasktracker.http.threads</name>
  <value>46</value>
  <final>true</final>
</property>
<property>
  <name>mapred.compress.map.output</name>
  <value>true</value>
</property>
<property>
  <name>mapred.output.compression.type</name>
  <value>BLOCK</value>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.default</name>
  <value>org.apache.hadoop.net.StandardSocketFactory</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.ClientProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.JobSubmissionProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>io.compression.codecs</name>
  <value>org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.GzipCodec</value>
</property>
<property>
  <name>fs.s3.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
<property>
  <name>fs.s3n.awsAccessKeyId</name>
  <value>$AWS_ACCESS_KEY_ID</value>
</property>
<property>
  <name>fs.s3n.awsSecretAccessKey</name>
  <value>$AWS_SECRET_ACCESS_KEY</value>
</property>
</configuration>
EOF

  # Keep PID files in a non-temporary directory
  sed -i -e "s|# export HADOOP_PID_DIR=.*|export HADOOP_PID_DIR=/var/run/hadoop|" \
    $HADOOP_CONF_DIR/hadoop-env.sh
  mkdir -p /var/run/hadoop
  chown -R hadoop:hadoop /var/run/hadoop

  # Set SSH options within the cluster
  sed -i -e 's|# export HADOOP_SSH_OPTS=.*|export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no"|' \
    $HADOOP_CONF_DIR/hadoop-env.sh

  # Hadoop logs should be on the /mnt partition
  sed -i -e 's|# export HADOOP_LOG_DIR=.*|export HADOOP_LOG_DIR=/var/log/hadoop/logs|' \
    $HADOOP_CONF_DIR/hadoop-env.sh
  rm -rf /var/log/hadoop
  mkdir /mnt/hadoop/logs
  chown hadoop:hadoop /mnt/hadoop/logs
  ln -s /mnt/hadoop/logs /var/log/hadoop
  chown -R hadoop:hadoop /var/log/hadoop

}

# Sets up small website on cluster.
function setup_web() {

  if which dpkg &> /dev/null; then
    apt-get -y install thttpd
    WWW_BASE=/var/www
  elif which rpm &> /dev/null; then
    yum install -y thttpd
    chkconfig --add thttpd
    WWW_BASE=/var/www/thttpd/html
  fi

  cat > $WWW_BASE/index.html << END
<html>
<head>
<title>Hadoop EC2 Cluster</title>
</head>
<body>
<h1>Hadoop EC2 Cluster</h1>
To browse the cluster you need to have a proxy configured.
Start the proxy with <tt>hadoop-ec2 proxy &lt;cluster_name&gt;</tt>,
and point your browser to
<a href="http://apache-hadoop-ec2.s3.amazonaws.com/proxy.pac">this Proxy
Auto-Configuration (PAC)</a> file.  To manage multiple proxy configurations,
you may wish to use
<a href="https://addons.mozilla.org/en-US/firefox/addon/2464">FoxyProxy</a>.
<ul>
<li><a href="http://$HYBRID_NN_HOST:50070/">NameNode</a>
<li><a href="http://$HYBRID_JT_HOST:50030/">JobTracker</a>
</ul>
</body>
</html>
END

  service thttpd start

}

function start_namenode() {
  if which dpkg &> /dev/null; then
    AS_HADOOP="su -s /bin/bash - hadoop -c"
  elif which rpm &> /dev/null; then
    AS_HADOOP="/sbin/runuser -s /bin/bash - hadoop -c"
  fi

  # Format HDFS
  [ ! -e $FIRST_MOUNT/hadoop/hdfs ] && $AS_HADOOP "$HADOOP_HOME/bin/hadoop namenode -format"

  $AS_HADOOP "$HADOOP_HOME/bin/hadoop-daemon.sh start namenode"

  $AS_HADOOP "$HADOOP_HOME/bin/hadoop dfsadmin -safemode wait"
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop fs -mkdir /user"
  # The following is questionable, as it allows a user to delete another user
  # It's needed to allow users to create their own user directories
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop fs -chmod +w /user"

}

function start_daemon() {
  if which dpkg &> /dev/null; then
    AS_HADOOP="su -s /bin/bash - hadoop -c"
  elif which rpm &> /dev/null; then
    AS_HADOOP="/sbin/runuser -s /bin/bash - hadoop -c"
  fi
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop-daemon.sh start $1"
}

function install_cassandra() {

    curl="curl --retry 3 --silent --show-error --fail"
    if [ ! -z "$CASSANDRA_URL" ]; then
        DEFAULT_CASSANDRA_URL=$CASSANDRA_URL
    fi

    cassandra_tar_file=`basename $DEFAULT_CASSANDRA_URL`
    $curl -O $DEFAULT_CASSANDRA_URL
    
    tar zxf $cassandra_tar_file -C /usr/local
    rm -f $cassandra_tar_file

    CASSANDRA_HOME_WITH_VERSION=/usr/local/`ls -1 /usr/local | grep cassandra`

    echo "export CASSANDRA_HOME=$CASSANDRA_HOME_ALIAS" >> ~root/.bash_profile
    echo 'export PATH=$CASSANDRA_HOME/bin:$PATH' >> ~root/.bash_profile
}

function configure_cassandra() {
  if [ -n "$EBS_MAPPINGS" ]; then
    # EBS_MAPPINGS is like "cn,/ebs1,/dev/sdj;cn,/ebs2,/dev/sdk"
    # EBS_MAPPINGS is like "ROLE,MOUNT_POINT,DEVICE;ROLE,MOUNT_POINT,DEVICE"
    for mapping in $(echo "$EBS_MAPPINGS" | tr ";" "\n"); do
      role=`echo $mapping | cut -d, -f1`
      mount=`echo $mapping | cut -d, -f2`
      device=`echo $mapping | cut -d, -f3`
      wait_for_mount $mount $device
    done
  fi

    if [ -f "$CASSANDRA_HOME_WITH_VERSION/conf/cassandra-env.sh" ]
    then
        # for cassandra 0.7.x we need to set the MAX_HEAP_SIZE env
        # variable so that it can be used in cassandra-env.sh on
        # startup
        if [ -z "$MAX_HEAP_SIZE" ]
        then
            INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`
            case $INSTANCE_TYPE in
            m1.xlarge|m2.xlarge)
                MAX_HEAP_SIZE="10G"
                ;;
            m1.large|c1.xlarge)
                MAX_HEAP_SIZE="5G"
                ;;
            *)
                # Don't set it and let cassandra-env figure it out
                ;;
            esac

            # write it to the profile
            echo "export MAX_HEAP_SIZE=$MAX_HEAP_SIZE" >> ~root/.bash_profile
            echo "export MAX_HEAP_SIZE=$MAX_HEAP_SIZE" >> ~root/.bashrc
        fi
    else
        write_cassandra_in_sh_file
    fi
}

function write_cassandra_in_sh_file {
  # for cassandra 0.6.x memory settings

  # configure the cassandra.in.sh script based on instance type
  INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`
  SETTINGS_FILE=$CASSANDRA_HOME_WITH_VERSION/bin/cassandra.in.sh

  cat > $SETTINGS_FILE <<EOF
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cassandra_home=$CASSANDRA_HOME_ALIAS

# The directory where Cassandra's configs live (required)
CASSANDRA_CONF=\$cassandra_home/conf

# This can be the path to a jar file, or a directory containing the 
# compiled classes. NOTE: This isn't needed by the startup script,
# it's just used here in constructing the classpath.
cassandra_bin=\$cassandra_home/build/classes
#cassandra_bin=\$cassandra_home/build/cassandra.jar

# JAVA_HOME can optionally be set here
#JAVA_HOME=/usr/local/jdk6

# The java classpath (required)
CLASSPATH=\$CASSANDRA_CONF:\$cassandra_bin

for jar in \$cassandra_home/lib/*.jar; do
    CLASSPATH=\$CLASSPATH:\$jar
done

EOF

  case $INSTANCE_TYPE in
  m1.xlarge|m2.xlarge)
    cat >> $SETTINGS_FILE <<EOF
# Arguments to pass to the JVM
JVM_OPTS="-ea -Xms10G -Xmx10G -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:SurvivorRatio=8 -XX:MaxTenuringThreshold=1 -XX:+HeapDumpOnOutOfMemoryError -Dcom.sun.management.jmxremote.port=8080 -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false"
EOF
    ;;
  m1.large|c1.xlarge)
    cat >> $SETTINGS_FILE <<EOF
# Arguments to pass to the JVM
JVM_OPTS="-ea -Xms5G -Xmx5G -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:SurvivorRatio=8 -XX:MaxTenuringThreshold=1 -XX:+HeapDumpOnOutOfMemoryError -Dcom.sun.management.jmxremote.port=8080 -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false"
EOF
    ;;
  *)
    cat >> $SETTINGS_FILE <<EOF
# Arguments to pass to the JVM
JVM_OPTS="-ea -Xms256M -Xmx1G -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:SurvivorRatio=8 -XX:MaxTenuringThreshold=1 -XX:+HeapDumpOnOutOfMemoryError -Dcom.sun.management.jmxremote.port=8080 -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.authenticate=false"
EOF
    ;;
  esac
}

function finish_cassandra {
    # symlink the actual cassandra directory to a more standard one (without version)
    # this is very important so the cluster can be configured more easily after the 
    # machines start and services started/stopped
    #
    # NOTE: Stratus also looks for this aliased directory to know when cassandra
    # is ready to be started
    ln -s $CASSANDRA_HOME_WITH_VERSION $CASSANDRA_HOME_ALIAS
}

register_auto_shutdown
install_user_packages
install_hadoop
configure_hadoop

for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  hybrid_nn)
    setup_web
    start_namenode
    ;;
  hybrid_snn)
    start_daemon secondarynamenode
    ;;
  hybrid_jt)
    start_daemon jobtracker
    ;;
  hybrid_dn)
    start_daemon datanode
    install_cassandra
    configure_cassandra
    finish_cassandra
    ;;
  hybrid_tt)
    start_daemon tasktracker
    ;;
  esac
done

