apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: logging
  namespace: ${namespace}
spec:
  version: ${version}
  count: ${replicas}
  elasticsearchRef:
    name: logging
  http:
    tls:
      selfSignedCertificate:
        subjectAltNames:
          - dns: kibana.${domain_name}
  podTemplate:
    spec:
      nodeSelector:
        role: general
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: kibana.k8s.elastic.co/name
                      operator: In
                      values: [logging]
                topologyKey: kubernetes.io/hostname
      containers:
        - name: kibana
          resources:
            requests:
              cpu: ${cpu_request}
              memory: ${memory_request}
            limits:
              cpu: "${cpu_limit}"
              memory: ${memory_limit}
  config:
    xpack.security.session.idleTimeout: "1h"
    xpack.security.session.lifespan: "24h"
    server.publicBaseUrl: "https://kibana.${domain_name}"
