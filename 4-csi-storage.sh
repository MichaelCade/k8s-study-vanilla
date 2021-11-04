#!/usr/bin/env bash


### Install command check ####
if type "kubectl" > /dev/null 2>&1
then
    echo "kubectl was already installed"
else
    echo "kubectl was not found. Please install kubectl and re-run"
    exit 255
fi

#### LOCALIP #########
ip address show ens160 >/dev/null
retval=$?
if [ ${retval} -eq 0 ]; then
        LOCALIPADDR=`ip -f inet -o addr show ens160 |cut -d\  -f 7 | cut -d/ -f 1`
else
  ip address show ens192 >/dev/null
  retval2=$?
  if [ ${retval2} -eq 0 ]; then
        LOCALIPADDR=`ip -f inet -o addr show ens192 |cut -d\  -f 7 | cut -d/ -f 1`
  else
        LOCALIPADDR=`ip -f inet -o addr show eth0 |cut -d\  -f 7 | cut -d/ -f 1`
  fi
fi
echo ${LOCALIPADDR}

BASEPWD=`pwd`

SNAPSHOTTER_VERSION=v4.2.1

# Apply VolumeSnapshot CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Create Snapshot Controller
kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

##Install the CSI Hostpath Driver
git clone  --depth 1 https://github.com/kubernetes-csi/csi-driver-host-path.git
cd csi-driver-host-path
./deploy/kubernetes-1.21/deploy.sh
kubectl apply -f ./examples/csi-storageclass.yaml
kubectl patch storageclass csi-hostpath-sc \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
cd ..
mv csi-driver-host-path csi-driver-host-path-`date "+%Y%m%d_%H%M%S"`


##Install NFS-CSI driver
apt -y install nfs-kernel-server
apt clean
mkdir -p /disk/k8s_share
chmod -R 1777 /disk/k8s_share
cat << EOF >> /etc/exports
/disk/k8s_share 192.168.0.0/16(rw,async,no_root_squash)
/disk/k8s_share 172.16.0.0/12(rw,async,no_root_squash)
/disk/k8s_share 10.0.0.0/8(rw,async,no_root_squash)
/disk/k8s_share 127.0.0.1/8(rw,async,no_root_squash)
EOF
systemctl restart nfs-server
systemctl enable nfs-server
showmount -e
NFSPATH=/disk/k8s_share
curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/install-driver.sh | bash -s master --
curl -OL  https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/example/storageclass-nfs.yaml
sed -i -e "s/nfs-server.default.svc.cluster.local/${LOCALIPADDR}/g" storageclass-nfs.yaml
sed -i -e "s@share: /@share: ${NFSPATH}@g" storageclass-nfs.yaml
kubectl create -f storageclass-nfs.yaml
rm -rf storageclass-nfs.yaml
kubectl patch storageclass nfs-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl -n kube-system get pod -o wide -l app=csi-nfs-controller
kubectl -n kube-system get pod -o wide -l app=csi-nfs-node
kubectl delete CSIDriver nfs.csi.k8s.io
cat <<EOF | kubectl create -f -
apiVersion: storage.k8s.io/v1beta1
kind: CSIDriver
metadata:
  name: nfs.csi.k8s.io
spec:
  attachRequired: false
  volumeLifecycleModes:
    - Persistent
  fsGroupPolicy: File
EOF


echo ""
echo "*************************************************************************************"
echo "There is no more action. following your current storage class"
echo ""

cd ${BASEPWD}
chmod -x ./4-csi-storage.sh
