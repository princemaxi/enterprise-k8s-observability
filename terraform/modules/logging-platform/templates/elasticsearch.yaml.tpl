apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: logging
  namespace: ${namespace}
spec:
  version: ${version}

  http:
    tls:
      selfSignedCertificate:
        subjectAltNames:
          - dns: logging-es-http.${namespace}.svc
          - dns: logging-es-http.${namespace}.svc.cluster.local

  # S3 snapshot credentials, loaded into the Elasticsearch keystore. This
  # is NOT a workaround — it's Elastic's own documented mechanism, and the
  # one that actually works here: both IRSA and EKS Pod Identity have
  # open, unresolved upstream bugs against repository-s3's bundled AWS
  # SDK (see docs/troubleshooting.md). The Secret this references is
  # created directly by Terraform (es-secret.tf), not by hand.
  secureSettings:
    - secretName: es-snapshot-credentials

  nodeSets:
    - name: master
      count: ${master_count}
      config:
        node.roles: ["master"]
        node.store.allow_mmap: false
      podTemplate:
        spec:
          tolerations:
            - key: dedicated
              operator: Equal
              value: es-master
              effect: NoSchedule
          nodeSelector:
            role: es-master
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchExpressions:
                      - key: elasticsearch.k8s.elastic.co/statefulset-name
                        operator: In
                        values: [logging-es-master]
                  topologyKey: topology.kubernetes.io/zone
          containers:
            - name: elasticsearch
              resources:
                requests:
                  cpu: "${master_cpu_request}"
                  memory: ${master_memory}
                limits:
                  cpu: "${master_cpu_limit}"
                  memory: ${master_memory}
              env:
                - name: ES_JAVA_OPTS
                  value: "-Xms${master_heap} -Xmx${master_heap}"
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: ${master_storage_gb}Gi
            storageClassName: es-gp3

    - name: data
      count: ${data_count}
      config:
        node.roles: ["data", "ingest"]
        node.store.allow_mmap: false
      podTemplate:
        spec:
          tolerations:
            - key: dedicated
              operator: Equal
              value: es-data
              effect: NoSchedule
          nodeSelector:
            role: es-data
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchExpressions:
                      - key: elasticsearch.k8s.elastic.co/statefulset-name
                        operator: In
                        values: [logging-es-data]
                  topologyKey: topology.kubernetes.io/zone
          containers:
            - name: elasticsearch
              resources:
                requests:
                  cpu: "${data_cpu_request}"
                  memory: ${data_memory}
                limits:
                  cpu: "${data_cpu_limit}"
                  memory: ${data_memory}
              env:
                - name: ES_JAVA_OPTS
                  value: "-Xms${data_heap} -Xmx${data_heap}"
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: ${data_storage_gb}Gi
            storageClassName: es-gp3
