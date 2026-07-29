${jsonencode(
{
    // This template specifies the available parameters for the different sizes of LogScale clusters
    // system_node          -> OKE system nodes for running system pod functions like coredns
    // logscale_digest      -> OKE nodes dedicated to core logscale systems (NVME attached storage) 
    // logscale_ingress     -> OKE nodes dedicated to proxy for access to control system access 
    // logscale_ingest      -> OKE nodes dedicated to logscale ingest nodes
    // logscale_ui          -> OKE nodes dedicated to UI nodes that do not handle data digest
    // strimzi_node         -> OKE nodes dedicated to strimzi kafka

    // Node pool configuration structure
    // Each node pool type has the following configuration options:
    // - enabled: boolean indicating if the node pool should be created
    // - name: display name for the node pool
    // - k8s_label: kubernetes label for node affinity
    // - shape: OCI compute shape
    // - ocpus: number of OCPUs
    // - memory_gb: memory in GB
    // - size: number of nodes
    // - boot_volume: boot volume size in GB
    // - user_data: user data script template
    // - min_node_count: minimum number of nodes for autoscaling
    // - max_node_count: maximum number of nodes for autoscaling
    // - desired_node_count: desired number of nodes
    // - instance_type: OCI compute instance type
    // - root_disk_size: root disk size in GB
    // - pod_count: number of pods to run on this node pool
    // - data_disk_size: data disk size
    // - resources: kubernetes resource limits and requests
    // - data_storage_class: storage class for data disks
    // - target_replication_factor: replication factor for data

    "node_pool_config": {
        "system_nodes": {
            "name": "system",
            "k8s_label": "system",
            "user_data": "user-data-system.sh.tmpl"
        },
        "strimzi_controller": {
            "name": "strimzi-controller",
            "k8s_label": "strimzi-controller",
            "user_data": "user-data-standard.sh.tmpl"
        },
        "strimzi_broker": {
            "name": "strimzi-broker",
            "k8s_label": "strimzi-broker",
            "user_data": "user-data-standard.sh.tmpl"
        },
        "logscale_digest": {
            "name": "logscale-digest",
            "k8s_label": "logscale-digest",
            "user_data": "nvme-storage-setup.sh"
        },
        "logscale_ingest": {
            "name": "logscale-ingest",
            "k8s_label": "logscale-ingest",
            "user_data": "user-data-standard.sh.tmpl"
        },
        "logscale_ui": {
            "name": "logscale-ui",
            "k8s_label": "logscale-ui",
            "user_data": "user-data-standard.sh.tmpl"
        },
        "logscale_ingress": {
            "name": "logscale-ingress",
            "k8s_label": "logscale-ingress",
            "user_data": "user-data-standard.sh.tmpl"
        }
    },

    "xsmall": {
        // system nodes
        "system_node_min_node_count": 2,
        "system_node_max_node_count": 5,
        "system_node_desired_node_count": 2,
        "system_node_instance_type": "VM.Standard.E5.Flex",
        "system_node_ocpus": 2,
        "system_node_memory_in_gbs": 8,
        "system_node_root_disk_size": 50,

        // kafka nodes
        "strimzi_node_instance_type": "VM.DenseIO.E5.Flex",
        "strimzi_node_min_node_count": 3,
        "strimzi_node_max_node_count": 5,
        "strimzi_node_desired_node_count": 3,
        "strimzi_node_ocpus": 8,
        "strimzi_node_memory_in_gbs": 96,
        "strimzi_node_root_disk_size": 50,

        // digest nodes
        "logscale_digest_instance_type": "VM.DenseIO.E5.Flex",
        "logscale_digest_root_disk_size": 50,
        "logscale_digest_min_node_count": 3,
        "logscale_digest_max_node_count": 3,
        "logscale_digest_desired_node_count": 3,
        "logscale_digest_ocpus": 8,
        "logscale_digest_memory_in_gbs": 96,

        // ingest nodes
        "logscale_ingest_min_node_count": 1,
        "logscale_ingest_max_node_count": 5,
        "logscale_ingest_desired_node_count": 3,
        "logscale_ingest_ocpus": 8,
        "logscale_ingest_memory_in_gbs": 96,
        "logscale_ingest_instance_type": "VM.DenseIO.E5.Flex",
        "logscale_ingest_root_disk_size": 50,

        // ingress nodes
        "logscale_ingress_min_node_count": 2,
        "logscale_ingress_max_node_count": 3,
        "logscale_ingress_desired_node_count": 2,
        "logscale_ingress_ocpus": 2,
        "logscale_ingress_memory_in_gbs": 8,
        "logscale_ingress_instance_type": "VM.Standard.E5.Flex",
        "logscale_ingress_root_disk_size": 50,
        "logscale_ingress_data_disk_size": "64Gi",
        "logscale_ingress_resources": {"limits": {"cpu": 1, "memory": "2Gi"}, "requests": {"cpu": 1, "memory": "2Gi"}},
        "logscale_basic_ingress_resources": {"limits": {"cpu": 1, "memory": "1Gi"}, "requests": {"cpu": 1, "memory": "1Gi"}},

        // ui nodes
        "logscale_ui_min_node_count": 1,
        "logscale_ui_max_node_count": 3,
        "logscale_ui_desired_node_count": 2,
        "logscale_ui_ocpus": 8,
        "logscale_ui_memory_in_gbs": 96,
        "logscale_ui_instance_type": "VM.DenseIO.E5.Flex",
        "logscale_ui_root_disk_size": 50,
    },

    "small": {
        // system nodes
        "system_node_min_node_count": 2,
        "system_node_max_node_count": 5,
        "system_node_desired_node_count": 3,
        "system_node_instance_type": "VM.Standard.E5.Flex",
        "system_node_ocpus": 2,
        "system_node_memory_in_gbs": 8,
        "system_node_root_disk_size": 50,

        // kafka nodes
        "strimzi_node_instance_type": "VM.DenseIO.E5.Flex",
        "strimzi_node_min_node_count": 5,
        "strimzi_node_max_node_count": 15,
        "strimzi_node_desired_node_count": 5,
        "strimzi_node_ocpus": 8,
        "strimzi_node_memory_in_gbs": 96,
        "strimzi_node_root_disk_size": 50,

        // digest nodes
        "logscale_digest_instance_type": "VM.DenseIO2.16",
        "logscale_digest_root_disk_size": 50,
        "logscale_digest_min_node_count": 6,
        "logscale_digest_max_node_count": 15,
        "logscale_digest_desired_node_count":6,
        "logscale_digest_ocpus": 14,
        "logscale_digest_memory_in_gbs": 128,

        // ingest nodes
        "logscale_ingest_min_node_count": 6,
        "logscale_ingest_max_node_count": 21,
        "logscale_ingest_desired_node_count": 6,
        "logscale_ingest_ocpus": 8,
        "logscale_ingest_memory_in_gbs": 32,
        "logscale_ingest_instance_type": "VM.DenseIO.E5.Flex",
        "logscale_ingest_root_disk_size": 50,

        // ingress nodes
        "logscale_ingress_min_node_count": 3,
        "logscale_ingress_max_node_count": 21,
        "logscale_ingress_desired_node_count": 3,
        "logscale_ingress_ocpus": 2,
        "logscale_ingress_memory_in_gbs": 8,
        "logscale_ingress_instance_type": "VM.Standard.E5.Flex",
        "logscale_ingress_root_disk_size": 50,
        "logscale_ingress_data_disk_size": "64Gi",
        "logscale_ingress_resources": {"limits": {"cpu": 1, "memory": "2Gi"}, "requests": {"cpu": 1, "memory": "2Gi"}},
        "logscale_basic_ingress_resources": {"limits": {"cpu": 1, "memory": "1Gi"}, "requests": {"cpu": 1, "memory": "1Gi"}},

        // ui nodes
        "logscale_ui_min_node_count": 3,
        "logscale_ui_max_node_count": 9,
        "logscale_ui_desired_node_count": 3,
        "logscale_ui_ocpus": 8,
        "logscale_ui_memory_in_gbs": 32,
        "logscale_ui_instance_type": "VM.DenseIO.E5.Flex",
        "logscale_ui_root_disk_size": 50,
    },
    "medium": {
        // system nodes
        "system_node_min_node_count": 2,
        "system_node_max_node_count": 12,
        "system_node_desired_node_count": 3,
        "system_node_instance_type": "VM.Standard.E4.Flex",
        "system_node_ocpus": 2,
        "system_node_memory_in_gbs": 8,
        "system_node_root_disk_size": 50,

        // kafka nodes
        "strimzi_node_instance_type": "VM.DenseIO.E5.Flex",
        "strimzi_node_min_node_count": 7,
        "strimzi_node_max_node_count": 21,
        "strimzi_node_desired_node_count": 7,
        "strimzi_node_ocpus": 16,
        "strimzi_node_memory_in_gbs": 192,
        "strimzi_node_root_disk_size": 50,

        // digest nodes
        "logscale_digest_instance_type": "VM.DenseIO2.16",
        "logscale_digest_root_disk_size": 50,
        "logscale_digest_min_node_count": 21,
        "logscale_digest_max_node_count": 45,
        "logscale_digest_desired_node_count":21,
        "logscale_digest_ocpus": 14,
        "logscale_digest_memory_in_gbs": 128,

        // ingest nodes
        "logscale_ingest_min_node_count": 15,
        "logscale_ingest_max_node_count": 45,
        "logscale_ingest_desired_node_count": 15,
        "logscale_ingest_ocpus": 16,
        "logscale_ingest_memory_in_gbs": 32,
        "logscale_ingest_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ingest_root_disk_size": 50,

        // ingress nodes
        "logscale_ingress_min_node_count": 6,
        "logscale_ingress_max_node_count": 33,
        "logscale_ingress_desired_node_count": 6,
        "logscale_ingress_ocpus": 6,
        "logscale_ingress_memory_in_gbs": 16,
        "logscale_ingress_instance_type": "VM.Standard.E4.Flex",
        "logscale_ingress_root_disk_size": 50,
        "logscale_ingress_data_disk_size": "64Gi",
        "logscale_ingress_resources": {"limits": {"cpu": 1, "memory": "2Gi"}, "requests": {"cpu": 1, "memory": "2Gi"}},
        "logscale_basic_ingress_resources": {"limits": {"cpu": 1, "memory": "1Gi"}, "requests": {"cpu": 1, "memory": "1Gi"}},

        // ui nodes
        "logscale_ui_min_node_count": 6,
        "logscale_ui_max_node_count": 21,
        "logscale_ui_desired_node_count": 6,
        "logscale_ui_ocpus": 8,
        "logscale_ui_memory_in_gbs": 16,
        "logscale_ui_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ui_root_disk_size": 50,
    },
    "large": {
        // system nodes
        "system_node_min_node_count": 3,
        "system_node_max_node_count": 21,
        "system_node_desired_node_count": 6,
        "system_node_instance_type": "VM.Standard.E4.Flex",
        "system_node_ocpus": 2,
        "system_node_memory_in_gbs": 8,
        "system_node_root_disk_size": 50,

        // kafka nodes
        "strimzi_node_instance_type": "VM.DenseIO.E5.Flex",
        "strimzi_node_min_node_count": 7,
        "strimzi_node_max_node_count": 30,
        "strimzi_node_desired_node_count": 9,
        "strimzi_node_ocpus": 16,
        "strimzi_node_memory_in_gbs": 192,
        "strimzi_node_root_disk_size": 50,

        // digest nodes
        "logscale_digest_instance_type": "VM.DenseIO2.24",
        "logscale_digest_root_disk_size": 50,
        "logscale_digest_min_node_count": 21,
        "logscale_digest_max_node_count": 60,
        "logscale_digest_desired_node_count":42,
        "logscale_digest_ocpus": 30,
        "logscale_digest_memory_in_gbs": 320,

        // ingest nodes
        "logscale_ingest_min_node_count": 15,
        "logscale_ingest_max_node_count": 45,
        "logscale_ingest_desired_node_count": 15,
        "logscale_ingest_ocpus": 32,
        "logscale_ingest_memory_in_gbs": 64,
        "logscale_ingest_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ingest_root_disk_size": 50,

        // ingress nodes
        "logscale_ingress_min_node_count": 6,
        "logscale_ingress_max_node_count": 33,
        "logscale_ingress_desired_node_count": 6,
        "logscale_ingress_ocpus": 14,
        "logscale_ingress_memory_in_gbs": 32,
        "logscale_ingress_instance_type": "VM.Standard.E4.Flex",
        "logscale_ingress_root_disk_size": 50,
        "logscale_ingress_data_disk_size": "64Gi",
        "logscale_ingress_resources": {"limits": {"cpu": 2, "memory": "4Gi"}, "requests": {"cpu": 1, "memory": "2Gi"}},
        "logscale_basic_ingress_resources": {"limits": {"cpu": 1, "memory": "1Gi"}, "requests": {"cpu": 1, "memory": "1Gi"}},

        // ui nodes
        "logscale_ui_min_node_count": 6,
        "logscale_ui_max_node_count": 21,
        "logscale_ui_desired_node_count": 9,
        "logscale_ui_ocpus": 16,
        "logscale_ui_memory_in_gbs": 32,
        "logscale_ui_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ui_root_disk_size": 50,
    },
    "xlarge": {
        // system nodes
        "system_node_min_node_count": 3,
        "system_node_max_node_count": 21,
        "system_node_desired_node_count": 6,
        "system_node_instance_type": "VM.Standard.E4.Flex",
        "system_node_ocpus": 2,
        "system_node_memory_in_gbs": 8,
        "system_node_root_disk_size": 50,

        // kafka nodes
        "strimzi_node_instance_type": "VM.DenseIO.E5.Flex",
        "strimzi_node_min_node_count": 12,
        "strimzi_node_max_node_count": 45,
        "strimzi_node_desired_node_count": 18,
        "strimzi_node_ocpus": 16,
        "strimzi_node_memory_in_gbs": 192,
        "strimzi_node_root_disk_size": 50,

        // digest nodes
        "logscale_digest_instance_type": "VM.DenseIO2.24",
        "logscale_digest_root_disk_size": 50,
        "logscale_digest_min_node_count": 26,
        "logscale_digest_max_node_count": 120,
        "logscale_digest_desired_node_count":78,
        "logscale_digest_ocpus": 62,
        "logscale_digest_memory_in_gbs": 640,

        // ingest nodes
        "logscale_ingest_min_node_count": 15,
        "logscale_ingest_max_node_count": 45,
        "logscale_ingest_desired_node_count": 18,
        "logscale_ingest_ocpus": 48,
        "logscale_ingest_memory_in_gbs": 96,
        "logscale_ingest_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ingest_root_disk_size": 50,

        // ingress nodes
        "logscale_ingress_min_node_count": 9,
        "logscale_ingress_max_node_count": 60,
        "logscale_ingress_desired_node_count": 18,
        "logscale_ingress_ocpus": 14,
        "logscale_ingress_memory_in_gbs": 32,
        "logscale_ingress_instance_type": "VM.Standard.E4.Flex",
        "logscale_ingress_root_disk_size": 50,
        "logscale_ingress_data_disk_size": "64Gi",
        "logscale_ingress_resources": {"limits": {"cpu": 2, "memory": "4Gi"}, "requests": {"cpu": 1, "memory": "2Gi"}},
        "logscale_basic_ingress_resources": {"limits": {"cpu": 1, "memory": "1Gi"}, "requests": {"cpu": 1, "memory": "1Gi"}},

        // ui nodes
        "logscale_ui_min_node_count": 12,
        "logscale_ui_max_node_count": 30,
        "logscale_ui_desired_node_count": 18,
        "logscale_ui_ocpus": 24,
        "logscale_ui_memory_in_gbs": 48,
        "logscale_ui_instance_type": "VM.DenseIO.E4.Flex",
        "logscale_ui_root_disk_size": 50,
    },
}
)}
